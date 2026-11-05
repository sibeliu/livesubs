# LiveSubs

Live English subtitles for Russian audio playing on your Mac: ok.ru, VK, YouTube, anything with sound. Everything runs locally.

```
system audio ─▶ Silero VAD ─▶ GigaAM v3 (Russian ASR) ─▶ Ollama LLM (ru→en) ─▶ floating subtitle window
```

- **Speech recognition:** [GigaAM v3](https://github.com/salute-developers/GigaAM) `e2e_rnnt`, which is more accurate on Russian than Whisper or Parakeet on non-studio speech ([benchmark](https://github.com/vakovalskii/stt-ru-benchmark)). About 0.15 s per sentence on an M-series GPU.
- **Translation:** any [Ollama](https://ollama.com) model. The previous few lines are passed as context.
- **Latency:** a line appears about 0.5 s after the speaker pauses, plus the translation time (about 0.5–2 s depending on the model).

## Requirements

- macOS 13+ on Apple Silicon (Intel works, but slower on CPU)
- Python 3.10–3.13, Xcode command line tools (`xcode-select --install`)
- [Ollama](https://ollama.com), running
- ffmpeg, only for the `--file` test mode

## Install

```sh
git clone <this repo> livesubs && cd livesubs
./setup.sh
```

On first run, LiveSubs downloads the GigaAM model (~450 MB, from Hugging Face) and pulls the Ollama translation model if it isn't installed yet.

## Run

Run it from **Terminal**:

```sh
./LiveSubs                         # translate with gemma4:31b (best quality, ~19 GB, ~2 s per line)
./LiveSubs --model gemma3:12b      # any Ollama model; smaller ones are faster
./LiveSubs --no-translate          # show the Russian transcript instead
```

The first time, macOS asks for **Screen & System Audio Recording** permission for Terminal. If it doesn't ask, enable it in System Settings → Privacy & Security, quit Terminal (⌘Q) and run again. LiveSubs only records audio: the video capture is limited to a 2×2 pixel stream that is discarded.

Drag the subtitle box to move it. The **Subs** menu bar item changes the text size, resets the position and quits. Ctrl-C in Terminal also quits.

## Options

All options are passed through to `worker.py`.

| flag | default | effect |
|---|---|---|
| `--model` | `gemma4:31b` | Ollama translation model |
| `--silence-ms` | 500 | pause that ends a subtitle line |
| `--max-seconds` | 10 | force a line break during long monologues |
| `--vad-threshold` | 0.5 | raise it if music triggers false speech |
| `--device` | `mps` | `cpu` to run the ASR model on the CPU |
| `-v` | | log timings and transcripts to stderr |

Test without capturing audio: `./LiveSubs --file clip.mp4 --realtime`, or run the worker alone with `.venv/bin/python worker.py --file clip.mp4 -v`.

## Files

- `LiveSubs.swift`: system-audio capture (ScreenCaptureKit) and the overlay window. Rebuild with `./build.sh`.
- `worker.py`: voice-activity segmentation, speech recognition, translation
- `asr.py`: loads GigaAM v3 from the [ai-sage/GigaAM-v3](https://huggingface.co/ai-sage/GigaAM-v3) Hugging Face repo, pinned to a fixed commit

## Credits

[GigaAM](https://github.com/salute-developers/GigaAM) (MIT) by SberDevices · [Silero VAD](https://github.com/snakers4/silero-vad) (MIT) · [Ollama](https://ollama.com)

## License

MIT, see [LICENSE](LICENSE).
