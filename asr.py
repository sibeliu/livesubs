"""GigaAM v3 e2e_rnnt (punctuated, normalized Russian ASR).

Weights come from Sber's Hugging Face repo (ai-sage/GigaAM-v3, branch e2e_rnnt), pinned to a
commit and downloaded to the Hugging Face cache on first use. They are mapped onto the classes
of the `gigaam` package.
"""
import json

import numpy as np
import torch
from huggingface_hub import hf_hub_download
from omegaconf import OmegaConf

from gigaam.model import GigaAMASR

HF_REPO = "ai-sage/GigaAM-v3"
HF_REVISION = "7655ad717f8122257385bb4b2f373db3697e8680"  # branch e2e_rnnt

_TARGETS = {
    "modeling_gigaam.FeatureExtractor": "gigaam.preprocess.FeatureExtractor",
    "modeling_gigaam.ConformerEncoder": "gigaam.encoder.ConformerEncoder",
    "modeling_gigaam.RNNTHead": "gigaam.decoder.RNNTHead",
    "modeling_gigaam.RNNTGreedyDecoding": "gigaam.decoding.RNNTGreedyDecoding",
}


def _fetch(filename: str) -> str:
    return hf_hub_download(HF_REPO, filename, revision=HF_REVISION)


def load(device: str = "mps") -> GigaAMASR:
    with open(_fetch("config.json")) as f:
        cfg = json.load(f)["cfg"]["model"]["cfg"]
    for part in ("preprocessor", "encoder", "head", "decoding"):
        cfg[part]["_target_"] = _TARGETS[cfg[part]["_target_"]]
    cfg["decoding"]["model_path"] = _fetch("tokenizer.model")
    model = GigaAMASR(OmegaConf.create(cfg))
    sd = torch.load(_fetch("pytorch_model.bin"), map_location="cpu", weights_only=True)
    model.load_state_dict({k.removeprefix("model."): v for k, v in sd.items()})
    model = model.eval()
    if device != "cpu":
        model.encoder = model.encoder.half()
    return model.to(device)


@torch.inference_mode()
def transcribe(model: GigaAMASR, audio: np.ndarray) -> str:
    """audio: mono float32 at 16 kHz, at most 25 s."""
    dev = model._device
    wav = torch.from_numpy(audio).to(dev).to(model._dtype).unsqueeze(0)
    length = torch.full([1], wav.shape[-1], device=dev)
    encoded, encoded_len = model.forward(wav, length)
    text, _ = model._decode(encoded, encoded_len, length, False)[0]
    return text
