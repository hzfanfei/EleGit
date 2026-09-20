"""TTS smoke test: Fun-CosyVoice3-0.5B-2512 (ModelScope / HuggingFace)."""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

from test_cosyvoice import (
    COSY,
    OUT,
    _hide_gpu_if_cuda_broken,
    _patch_torchaudio_load,
    pcm16_to_wav,
)

OUT_WAV = OUT / "cosyvoice3_test.wav"
REPORT_PATH = OUT / "cosyvoice3_report.json"

# ModelScope id (see CosyVoice README)
MODEL_ID = "FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
TTS_TEXT = "\u4f60\u597d\uff0c\u8fd9\u662f\u95ee\u8c61 Fun-CosyVoice3 \u672c\u5730\u5408\u6210\u6d4b\u8bd5\u3002"
PROMPT_TEXT = (
    "You are a helpful assistant.<|endofprompt|>"
    "\u5e0c\u671b\u4f60\u4ee5\u540e\u80fd\u591f\u505a\u7684\u6bd4\u6211\u8fd8\u597d\u5456\u3002"
)


def main() -> int:
    if not COSY.is_dir():
        print("CosyVoice not cloned. Run setup.ps1 first.", file=sys.stderr)
        return 2

    prompt_wav = COSY / "asset" / "zero_shot_prompt.wav"
    if not prompt_wav.is_file():
        print(f"Missing {prompt_wav}; run git submodule update in CosyVoice.", file=sys.stderr)
        return 2

    _hide_gpu_if_cuda_broken()
    sys.path.insert(0, str(COSY))
    sys.path.insert(0, str(COSY / "third_party" / "Matcha-TTS"))
    _patch_torchaudio_load()

    import torch

    device = (
        "cuda"
        if torch.cuda.is_available() and torch.cuda.device_count() > 0
        else "cpu"
    )
    if device == "cuda":
        print(f"gpu: {torch.cuda.get_device_name(0)}")
    print(f"device: {device}")

    try:
        from cosyvoice.cli.cosyvoice import CosyVoice3
    except ImportError as err:
        print(f"CosyVoice3 import failed: {err}", file=sys.stderr)
        return 3

    t0 = time.perf_counter()
    use_cuda = device == "cuda"
    cosy = CosyVoice3(MODEL_ID, load_trt=False, fp16=use_cuda)
    load_s = time.perf_counter() - t0
    print(f"model load: {load_s:.2f}s")

    t1 = time.perf_counter()
    chunks = []
    sample_rate = 24000
    for i, out in enumerate(
        cosy.inference_zero_shot(
            TTS_TEXT, PROMPT_TEXT, str(prompt_wav), stream=False
        )
    ):
        if i == 0 and hasattr(out, "get"):
            sample_rate = int(out.get("sample_rate", sample_rate))
        speech = out["tts_speech"]
        if hasattr(speech, "detach"):
            speech = speech.detach().cpu().numpy()
        import numpy as np

        arr = np.asarray(speech).squeeze()
        if arr.dtype != np.int16:
            arr = (arr * 32767).clip(-32768, 32767).astype(np.int16)
        chunks.append(arr.tobytes())
    infer_s = time.perf_counter() - t1

    pcm = b"".join(chunks)
    pcm16_to_wav(pcm, OUT_WAV, sample_rate=sample_rate)
    report = {
        "ok": len(pcm) > 0,
        "model": MODEL_ID,
        "device": device,
        "load_sec": round(load_s, 3),
        "infer_sec": round(infer_s, 3),
        "sample_rate": sample_rate,
        "pcm_bytes": len(pcm),
        "wav": str(OUT_WAV),
        "text": TTS_TEXT,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    REPORT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
