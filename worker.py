"""Live Russian speech -> Russian text (GigaAM) -> English (local LLM via Ollama).

Reads mono float32 16 kHz PCM on stdin (from the LiveSubs app) or from a file (--file),
writes JSON lines on stdout:
  {"type": "status", "text": ...}      loading / downloading progress
  {"type": "ready"}                    models loaded, start sending audio
  {"type": "line", "text": ...}        a subtitle line (English, or Russian with --no-translate)
"""
import argparse
import json
import queue
import subprocess
import sys
import threading
import time
import warnings

import numpy as np
import requests
import torch

warnings.filterwarnings("ignore")

SR = 16000
FRAME = 512  # samples per VAD frame (32 ms), required by Silero at 16 kHz

SYSTEM_PROMPT = (
    "You translate live Russian video subtitles into natural, idiomatic English. "
    "The Russian comes from speech recognition and may contain small errors; infer the intended meaning. "
    "Earlier lines are given only for context. Translate only the line marked NEW. "
    "Output only the English translation, nothing else."
)


def emit(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def status(text):
    log(f"[worker] {text}")
    emit({"type": "status", "text": text})


class Translator(threading.Thread):
    def __init__(self, model: str, url: str, context_lines: int = 3):
        super().__init__(daemon=True)
        self.model, self.url, self.context_lines = model, url, context_lines
        self.q = queue.Queue()
        self.history = []  # (ru, en)

    def ensure_model(self):
        """Check Ollama is up and pull the translation model if it isn't installed."""
        try:
            tags = requests.get(f"{self.url}/api/tags", timeout=5).json()
        except requests.RequestException:
            sys.exit(f"[worker] Ollama is not running at {self.url}. Install it from https://ollama.com and start it.")
        names = {m["name"] for m in tags.get("models", [])}
        if self.model in names or f"{self.model}:latest" in names:
            return
        status(f"Downloading translation model {self.model}…")
        with requests.post(f"{self.url}/api/pull", json={"model": self.model}, stream=True) as r:
            last = 0
            for raw in r.iter_lines():
                ev = json.loads(raw)
                if "error" in ev:
                    sys.exit(f"[worker] could not pull {self.model}: {ev['error']}")
                if ev.get("total") and time.time() - last > 1:
                    last = time.time()
                    status(f"Downloading {self.model}: {100 * ev.get('completed', 0) // ev['total']}%")

    def warm_up(self):
        try:
            requests.post(f"{self.url}/api/generate",
                          json={"model": self.model, "prompt": "", "keep_alive": "60m"}, timeout=300)
        except requests.RequestException as e:
            log(f"[translate] warm-up failed: {e}")

    def translate(self, ru: str) -> str:
        ctx = "\n".join(f"- {r} => {e}" for r, e in self.history[-self.context_lines:])
        user = (f"Earlier lines:\n{ctx}\n\n" if ctx else "") + f"NEW: {ru}"
        r = requests.post(f"{self.url}/api/chat", timeout=60, json={
            "model": self.model, "stream": False, "keep_alive": "60m", "think": False,
            "options": {"temperature": 0},
            "messages": [{"role": "system", "content": SYSTEM_PROMPT},
                         {"role": "user", "content": user}],
        })
        r.raise_for_status()
        return r.json()["message"]["content"].strip()

    def run(self):
        while True:
            ru = self.q.get()
            # if we've fallen behind, merge queued lines so subtitles stay current
            merged = 1
            while not self.q.empty():
                ru, merged = f"{ru} {self.q.get()}", merged + 1
            try:
                t = time.time()
                en = self.translate(ru)
                if args.verbose:
                    log(f"[translate] {time.time()-t:.2f}s  {ru} => {en}")
                self.history.append((ru, en))
                emit({"type": "line", "text": en})
            except Exception as e:
                log(f"[translate] {e}")
            finally:
                for _ in range(merged):
                    self.q.task_done()


class Segmenter:
    """Silero VAD over a PCM stream: cuts at pauses, forces a cut on long monologues."""

    def __init__(self, asr_model, transcribe, translator, args):
        from silero_vad import load_silero_vad
        self.vad = load_silero_vad()
        self.asr_model, self.transcribe, self.translator = asr_model, transcribe, translator
        self.threshold = args.vad_threshold
        self.end_silence = int(args.silence_ms / 1000 * SR / FRAME)
        self.max_frames = int(args.max_seconds * SR / FRAME)
        self.preroll = 10  # frames (~320 ms) of audio kept before speech onset
        self.ring = []
        self.speech = []
        self.in_speech = False
        self.silent = 0

    def _finish(self):
        frames = self.speech[:len(self.speech) - max(0, self.silent - 3)]  # trim trailing silence
        self.speech, self.in_speech, self.silent = [], False, 0
        if len(frames) < 8:  # < ~250 ms: noise
            return
        audio = np.concatenate(frames)
        t = time.time()
        text = self.transcribe(self.asr_model, audio).strip()
        if args.verbose:
            log(f"[asr] {len(audio)/SR:.1f}s audio in {time.time()-t:.2f}s: {text}")
        if not text:
            return
        if self.translator:
            self.translator.q.put(text)
        else:
            emit({"type": "line", "text": text})

    def push_frame(self, frame: np.ndarray):
        voiced = self.vad(torch.from_numpy(frame), SR).item() >= self.threshold
        if not self.in_speech:
            self.ring.append(frame)
            self.ring = self.ring[-self.preroll:]
            if voiced:
                self.in_speech, self.speech, self.ring, self.silent = True, list(self.ring), [], 0
            return
        self.speech.append(frame)
        self.silent = 0 if voiced else self.silent + 1
        if self.silent >= self.end_silence or len(self.speech) >= self.max_frames:
            self._finish()

    def flush(self):
        if self.in_speech:
            self._finish()


def pcm_stream(args):
    """Yield float32 frames of FRAME samples from stdin or a file decoded by ffmpeg."""
    if args.file:
        proc = subprocess.Popen(["ffmpeg", "-nostdin", "-loglevel", "error", "-i", args.file,
                                 "-f", "f32le", "-ac", "1", "-ar", str(SR), "-"], stdout=subprocess.PIPE)
        src = proc.stdout
    else:
        src = sys.stdin.buffer
    nbytes = FRAME * 4
    buf = b""
    t0 = time.time()
    n = 0
    while True:
        chunk = src.read(nbytes - len(buf)) if args.file else src.read1(65536)
        if not chunk:
            break
        buf += chunk
        while len(buf) >= nbytes:
            yield np.frombuffer(buf[:nbytes], dtype=np.float32).copy()
            buf = buf[nbytes:]
            n += 1
            if args.file and args.realtime:  # pace file playback like live audio
                ahead = n * FRAME / SR - (time.time() - t0)
                if ahead > 0:
                    time.sleep(ahead)


def main():
    global args
    p = argparse.ArgumentParser()
    p.add_argument("--file", help="read audio from a file instead of stdin (for testing)")
    p.add_argument("--realtime", action="store_true", help="with --file: feed at playback speed")
    p.add_argument("--model", default="gemma4:31b", help="Ollama model for translation")
    p.add_argument("--ollama", default="http://localhost:11434")
    p.add_argument("--no-translate", action="store_true", help="show the Russian transcript instead")
    p.add_argument("--device", default="mps" if torch.backends.mps.is_available() else "cpu")
    p.add_argument("--vad-threshold", type=float, default=0.5)
    p.add_argument("--silence-ms", type=int, default=500, help="pause that ends a subtitle line")
    p.add_argument("--max-seconds", type=float, default=10, help="force a line break after this long")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args()

    translator = None
    if not args.no_translate:
        translator = Translator(args.model, args.ollama)
        translator.ensure_model()

    import asr
    status("Loading speech model (first run downloads ~450 MB)…")
    model = asr.load(args.device)
    asr.transcribe(model, np.zeros(SR, dtype=np.float32))  # warm-up (first MPS call is slow)
    if translator:
        status("Loading translation model…")
        translator.warm_up()
        translator.start()
    seg = Segmenter(model, asr.transcribe, translator, args)
    emit({"type": "ready"})
    log("[worker] ready")
    for frame in pcm_stream(args):
        seg.push_frame(frame)
    seg.flush()
    if translator:  # let pending translations finish (file mode)
        translator.q.join()


if __name__ == "__main__":
    main()
