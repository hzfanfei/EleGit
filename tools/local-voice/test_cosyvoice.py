"""TTS smoke test via CosyVoice repo (CosyVoice2-0.5B, GPU if available)."""
from __future__ import annotations

import json
import sys
import time
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent
COSY = ROOT / "CosyVoice"
# Prefer isolated CosyVoice venv when present (see setup-cosyvoice.ps1).
_VENV_COSY = ROOT / ".venv-cosyvoice" / "Scripts" / "python.exe"
if _VENV_COSY.exists() and Path(sys.executable).resolve() != _VENV_COSY.resolve():
    print(f"Tip: run with {_VENV_COSY} for CosyVoice deps", file=sys.stderr)
OUT = ROOT / "output"
OUT_WAV = OUT / "cosyvoice_test.wav"


def pcm16_to_wav(pcm: bytes, path: Path, sample_rate: int = 24000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm)


def _patch_torchaudio_load() -> None:
    """torchaudio 2.11+ defaults to torchcodec; soundfile is enough for CosyVoice wav prompts."""
    import torch
    import soundfile as sf
    import torchaudio

    def _load(path, frame_offset=0, num_frames=-1, normalize=True, channels_first=True, **kwargs):
        del frame_offset, num_frames, normalize, channels_first, kwargs
        data, sr = sf.read(path, dtype="float32", always_2d=True)
        return torch.from_numpy(data.T), sr

    torchaudio.load = _load  # type: ignore[method-assign]


def _hide_gpu_if_cuda_broken() -> None:
    """CosyVoice picks cuda at import/init; probe in a subprocess before torch loads."""
    import os
    import subprocess

    if os.environ.get("LOCAL_VOICE_FORCE_CPU", "").lower() in ("1", "true", "yes"):
        os.environ["CUDA_VISIBLE_DEVICES"] = ""
        return
    if os.environ.get("CUDA_VISIBLE_DEVICES") == "":
        return
    probe = subprocess.run(
        [
            sys.executable,
            "-c",
            "import torch\n"
            "if not torch.cuda.is_available():\n"
            "    print('cpu')\n"
            "else:\n"
            "    try:\n"
            "        torch.zeros(1, device='cuda')\n"
            "        print('gpu')\n"
            "    except RuntimeError:\n"
            "        print('cpu')\n",
        ],
        capture_output=True,
        text=True,
        timeout=120,
    )
    if probe.stdout.strip() != "gpu":
        os.environ["CUDA_VISIBLE_DEVICES"] = ""


def main() -> int:
    import os

    if not COSY.is_dir():
        print("CosyVoice not cloned. Run setup.ps1 first.", file=sys.stderr)
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
        from cosyvoice.cli.cosyvoice import CosyVoice2
    except ImportError as err:
        print(f"CosyVoice import failed: {err}", file=sys.stderr)
        print("Try: pip install -r CosyVoice/requirements.txt (in venv)", file=sys.stderr)
        return 3

    model_id = "iic/CosyVoice2-0.5B"
    text = "\u4f60\u597d\uff0c\u8fd9\u662f\u95ee\u8c61\u672c\u5730\u8bed\u97f3\u5408\u6210\u6d4b\u8bd5\u3002"
    prompt_text = "\u5e0c\u671b\u4f60\u4ee5\u540e\u80fd\u591f\u505a\u7684\u6bd4\u6211\u8fd8\u597d\u5456\u3002"
    prompt_wav = COSY / "asset" / "zero_shot_prompt.wav"
    if not prompt_wav.is_file():
        print(f"Missing {prompt_wav}; run setup submodule init.", file=sys.stderr)
        return 2

    t0 = time.perf_counter()
    use_cuda = device == "cuda"
    cosy = CosyVoice2(model_id, load_jit=False, load_trt=False, fp16=use_cuda)
    load_s = time.perf_counter() - t0
    print(f"model load: {load_s:.2f}s")

    t1 = time.perf_counter()
    chunks = []
    sample_rate = 24000
    for i, out in enumerate(
        cosy.inference_zero_shot(text, prompt_text, str(prompt_wav), stream=False)
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
        "device": device,
        "load_sec": round(load_s, 3),
        "infer_sec": round(infer_s, 3),
        "sample_rate": sample_rate,
        "pcm_bytes": len(pcm),
        "wav": str(OUT_WAV),
        "text": text,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    (OUT / "cosyvoice_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
