"""Compare CosyVoice3 zero-shot speakers (multiple cached spk ids)."""
from __future__ import annotations

import json
import subprocess
import sys
import time
import urllib.request
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent
COSY = ROOT / "CosyVoice"
OUT = ROOT / "output"
TTS_TEXT = "你好，这是问象 CosyVoice 多音色试听。今天天气不错，我们一起读一段书吧。"

ALT_VOICES = [
    {
        "id": "wenxiang_default",
        "prompt_wav": COSY / "asset" / "zero_shot_prompt.wav",
        "prompt_text": (
            "You are a helpful assistant.<|endofprompt|>"
            "希望你以后能够做的比我还好呦。"
        ),
    },
    {
        "id": "en_setup_ref",
        "prompt_wav": OUT / "sample_en.wav",
        "prompt_text": (
            "You are a helpful assistant.<|endofprompt|>"
            "Hello, this is a local FunASR smoke test."
        ),
    },
    {
        "id": "en_zira_ref",
        "prompt_wav": OUT / "cosyvoice_prompt_zira.wav",
        "prompt_text": (
            "You are a helpful assistant.<|endofprompt|>"
            "Hello, this is an English reference voice for cross timbre cloning."
        ),
        "win_voice": "Microsoft Zira Desktop",
        "win_line": "Hello, this is an English reference voice for cross timbre cloning.",
    },
]


def _ensure_download_prompt_wav(entry: dict) -> None:
    wav: Path = entry["prompt_wav"]
    if wav.is_file() and wav.stat().st_size > 1000:
        return
    url = entry.get("download_url")
    if not url:
        raise RuntimeError(f"Missing prompt wav: {wav}")
    OUT.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": "wenxiang-local-voice-test/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        wav.write_bytes(resp.read())


def _ensure_win_prompt_wav(entry: dict) -> None:
    wav: Path = entry["prompt_wav"]
    if wav.is_file() and wav.stat().st_size > 1000:
        return
    voice = entry.get("win_voice")
    line = entry.get("win_line")
    if not voice or not line:
        raise RuntimeError(f"Missing prompt wav: {wav}")
    OUT.mkdir(parents=True, exist_ok=True)
    ps = f"""
Add-Type -AssemblyName System.Speech
$s = New-Object System.Speech.Synthesis.SpeechSynthesizer
$s.SelectVoice('{voice.replace("'", "''")}')
$s.SetOutputToWaveFile('{wav.as_posix()}')
$s.Speak('{line.replace("'", "''")}')
$s.Dispose()
"""
    subprocess.run(
        ["powershell", "-NoProfile", "-Command", ps],
        check=True,
        capture_output=True,
        text=True,
    )


def _pcm_from_speech(cosy, text: str, spk_id: str) -> tuple[bytes, int]:
    import numpy as np

    sample_rate = int(getattr(cosy, "sample_rate", 24000))
    chunks: list[bytes] = []
    for out in cosy.inference_zero_shot(
        text,
        "",
        "",
        zero_shot_spk_id=spk_id,
        stream=False,
        text_frontend=True,
    ):
        speech = out["tts_speech"]
        if hasattr(speech, "detach"):
            speech = speech.detach().cpu().numpy()
        arr = np.asarray(speech).squeeze()
        if arr.size == 0:
            continue
        if arr.dtype != np.int16:
            arr = (arr * 32767).clip(-32768, 32767).astype(np.int16)
        chunks.append(arr.tobytes())
        sample_rate = int(out.get("sample_rate", sample_rate))
    return b"".join(chunks), sample_rate


def _write_wav(pcm: bytes, path: Path, sample_rate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(sample_rate)
        wf.writeframes(pcm)


def main() -> int:
    if not COSY.is_dir():
        print("CosyVoice not cloned.", file=sys.stderr)
        return 2

    sys.path.insert(0, str(COSY))
    sys.path.insert(0, str(COSY / "third_party" / "Matcha-TTS"))
    from test_cosyvoice import _hide_gpu_if_cuda_broken, _patch_torchaudio_load

    _hide_gpu_if_cuda_broken()
    _patch_torchaudio_load()

    import torch
    from cosyvoice.cli.cosyvoice import CosyVoice3

    device = "cuda" if torch.cuda.is_available() and torch.cuda.device_count() > 0 else "cpu"
    print(f"device: {device}")

    for entry in ALT_VOICES:
        if entry.get("win_voice"):
            _ensure_win_prompt_wav(entry)
        elif entry.get("download_url"):
            _ensure_download_prompt_wav(entry)
        elif not Path(entry["prompt_wav"]).is_file():
            print(f"Missing {entry['prompt_wav']}", file=sys.stderr)
            return 2

    model_id = "FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
    t0 = time.perf_counter()
    cosy = CosyVoice3(model_id, load_trt=False, fp16=(device == "cuda"))
    print(f"model load: {time.perf_counter() - t0:.2f}s")

    report = {"text": TTS_TEXT, "device": device, "voices": []}
    for entry in ALT_VOICES:
        spk_id = entry["id"]
        t_cache = time.perf_counter()
        cosy.add_zero_shot_spk(entry["prompt_text"], str(entry["prompt_wav"]), spk_id)
        cache_ms = round((time.perf_counter() - t_cache) * 1000, 1)
        t_inf = time.perf_counter()
        pcm, sr = _pcm_from_speech(cosy, TTS_TEXT, spk_id)
        infer_ms = round((time.perf_counter() - t_inf) * 1000, 1)
        out_wav = OUT / f"cosyvoice_voice_{spk_id}.wav"
        _write_wav(pcm, out_wav, sr)
        row = {
            "id": spk_id,
            "cache_ms": cache_ms,
            "infer_ms": infer_ms,
            "pcm_bytes": len(pcm),
            "wav": str(out_wav.relative_to(ROOT)),
        }
        report["voices"].append(row)
        print(json.dumps(row, ensure_ascii=False))

    (OUT / "cosyvoice_alt_voices_report.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"spks registered: {cosy.list_available_spks()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
