"""Offline ASR smoke test (FunASR Paraformer, GPU if available)."""
from __future__ import annotations

import json
import sys
import time
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent
OUT = ROOT / "output"
SAMPLE_WAV = OUT / "sample_en.wav"


def ensure_sample_wav() -> Path:
    OUT.mkdir(parents=True, exist_ok=True)
    if SAMPLE_WAV.exists() and SAMPLE_WAV.stat().st_size > 1000:
        return SAMPLE_WAV
    local = ROOT / "sample_zh.wav"
    if local.exists() and local.stat().st_size > 1000:
        return local
    urls = [
        "https://github.com/modelscope/FunASR/raw/main/tests/data/zh.wav",
        "https://isv-data.oss-cn-hangzhou.aliyuncs.com/ics/MaaS/ASR/sample_audio/asr_example_zh.wav",
    ]
    last_err = None
    for url in urls:
        try:
            print(f"Downloading sample wav from {url} …")
            req = urllib.request.Request(url, headers={"User-Agent": "wenxiang-local-voice-test/1.0"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                SAMPLE_WAV.write_bytes(resp.read())
            if SAMPLE_WAV.stat().st_size > 1000:
                return SAMPLE_WAV
        except Exception as err:
            last_err = err
    raise RuntimeError(f"Could not download sample wav: {last_err}")


def main() -> int:
    import torch
    from funasr import AutoModel

    device = "cuda:0" if torch.cuda.is_available() else "cpu"
    if device.startswith("cuda"):
        print(f"gpu: {torch.cuda.get_device_name(0)}")
        try:
            torch.zeros(1, device=device)
        except RuntimeError as err:
            print(f"cuda unusable ({err}); falling back to cpu")
            device = "cpu"
    print(f"device: {device}")

    wav = ensure_sample_wav()
    with wave.open(str(wav), "rb") as wf:
        print(f"sample: {wf.getframerate()} Hz, {wf.getnframes()} frames, {wf.getnchannels()} ch")

    t0 = time.perf_counter()
    model = AutoModel(
        model="paraformer-zh",
        device=device,
        disable_update=True,
    )
    load_s = time.perf_counter() - t0
    print(f"model load: {load_s:.2f}s")

    t1 = time.perf_counter()
    result = model.generate(input=str(wav))
    infer_s = time.perf_counter() - t1

    text = ""
    if result and isinstance(result, list):
        text = str(result[0].get("text", "") if isinstance(result[0], dict) else result[0])
    report = {
        "ok": bool(text.strip()),
        "device": device,
        "load_sec": round(load_s, 3),
        "infer_sec": round(infer_s, 3),
        "text": text.strip(),
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    (OUT / "funasr_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
