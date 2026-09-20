"""Latency bench: one model load + streaming TTFT (Fun-CosyVoice3)."""
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
)

REPORT_PATH = OUT / "cosyvoice3_latency_report.json"
MODEL_ID = "FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
PROMPT_TEXT = (
    "You are a helpful assistant.<|endofprompt|>"
    "\u5e0c\u671b\u4f60\u4ee5\u540e\u80fd\u591f\u505a\u7684\u6bd4\u6211\u8fd8\u597d\u5456\u3002"
)
UTTERANCES = [
    "\u4f60\u597d\uff0c\u8fd9\u662f\u95ee\u8c61\u672c\u5730\u8bed\u97f3\u5408\u6210\u6d4b\u8bd5\u3002",
    "\u8bf7\u7528\u81ea\u7136\u7684\u8bed\u6c14\u518d\u8bf4\u4e00\u53e5\uff0c\u4eca\u5929\u5929\u6c14\u4e0d\u9519\u3002",
]
CACHED_SPK_ID = "wenxiang_bench_spk"


def _speech_pcm_bytes(out: dict) -> tuple[int, bytes]:
    import numpy as np

    speech = out["tts_speech"]
    if hasattr(speech, "detach"):
        speech = speech.detach().cpu().numpy()
    arr = np.asarray(speech).squeeze()
    if arr.size == 0:
        return 24000, b""
    sr = int(out.get("sample_rate", 24000)) if hasattr(out, "get") else 24000
    if arr.dtype != np.int16:
        arr = (arr * 32767).clip(-32768, 32767).astype(np.int16)
    return sr, arr.tobytes()


def _stream_once(
    cosy,
    text: str,
    prompt_wav: Path,
    *,
    zero_shot_spk_id: str = "",
    text_frontend: bool = True,
) -> dict:
    t0 = time.perf_counter()
    ttft_ms = None
    chunks_pcm: list[bytes] = []
    sample_rate = 24000
    n_chunks = 0
    prompt_text = "" if zero_shot_spk_id else PROMPT_TEXT
    wav_arg = "" if zero_shot_spk_id else str(prompt_wav)
    for out in cosy.inference_zero_shot(
        text,
        prompt_text,
        wav_arg,
        zero_shot_spk_id=zero_shot_spk_id,
        stream=True,
        text_frontend=text_frontend,
    ):
        n_chunks += 1
        sample_rate, pcm = _speech_pcm_bytes(out)
        if pcm:
            chunks_pcm.append(pcm)
        if ttft_ms is None and pcm:
            ttft_ms = (time.perf_counter() - t0) * 1000
    total_ms = (time.perf_counter() - t0) * 1000
    pcm_all = b"".join(chunks_pcm)
    audio_sec = len(pcm_all) / (2 * sample_rate) if pcm_all else 0.0
    return {
        "ttft_ms": round(ttft_ms or total_ms, 1),
        "total_ms": round(total_ms, 1),
        "stream_chunks": n_chunks,
        "pcm_bytes": len(pcm_all),
        "audio_sec": round(audio_sec, 3),
        "rtf": round((total_ms / 1000) / audio_sec, 3) if audio_sec > 0 else None,
        "zero_shot_spk_id": zero_shot_spk_id or None,
        "text_frontend": text_frontend,
    }


def main() -> int:
    if not COSY.is_dir():
        print("CosyVoice not cloned.", file=sys.stderr)
        return 2
    prompt_wav = COSY / "asset" / "zero_shot_prompt.wav"
    if not prompt_wav.is_file():
        print(f"Missing {prompt_wav}", file=sys.stderr)
        return 2

    _hide_gpu_if_cuda_broken()
    sys.path.insert(0, str(COSY))
    sys.path.insert(0, str(COSY / "third_party" / "Matcha-TTS"))
    _patch_torchaudio_load()

    import torch
    from cosyvoice.cli.cosyvoice import CosyVoice3

    device = (
        "cuda"
        if torch.cuda.is_available() and torch.cuda.device_count() > 0
        else "cpu"
    )
    print(f"device: {device}")

    t_load = time.perf_counter()
    cosy = CosyVoice3(MODEL_ID, load_trt=False, fp16=(device == "cuda"))
    load_ms = (time.perf_counter() - t_load) * 1000

    t_cache = time.perf_counter()
    cosy.add_zero_shot_spk(PROMPT_TEXT, str(prompt_wav), CACHED_SPK_ID)
    cache_spk_ms = (time.perf_counter() - t_cache) * 1000

    runs = []
    # 1) Full zero-shot each time (slow TTFT: ONNX prompt + LLM token buffer)
    row = _stream_once(cosy, UTTERANCES[0], prompt_wav)
    row["mode"] = "zero_shot_cold"
    row["utterance"] = 1
    row["text_len"] = len(UTTERANCES[0])
    row["e2e_first_audio_ms"] = round(load_ms + row["ttft_ms"], 1)
    runs.append(row)

    # 2) Cached speaker — production-style warm path
    for idx, text in enumerate(UTTERANCES):
        row = _stream_once(
            cosy,
            text,
            prompt_wav,
            zero_shot_spk_id=CACHED_SPK_ID,
            text_frontend=True,
        )
        row["mode"] = "cached_spk_warm"
        row["utterance"] = idx + 1
        row["text_len"] = len(text)
        if idx == 0:
            row["e2e_first_audio_ms"] = round(
                load_ms + cache_spk_ms + row["ttft_ms"], 1
            )
        runs.append(row)

    report = {
        "model": MODEL_ID,
        "device": device,
        "load_ms": round(load_ms, 1),
        "cache_spk_ms": round(cache_spk_ms, 1),
        "stream": True,
        "runs": runs,
        "notes": {
            "load_ms": "CosyVoice3() init once per process",
            "cache_spk_ms": "add_zero_shot_spk once (ONNX prompt encode; amortize at startup)",
            "zero_shot_cold": "re-runs campplus + speech_tokenizer_v3 ONNX on prompt every utterance",
            "cached_spk_warm": "uses spk2info; skips prompt ONNX — use in a long-lived service",
            "ttft_ms": "until first non-empty PCM chunk (stream=True; model waits for ~25 speech tokens + 100ms poll)",
            "volc_compare": "from repo root: cd server && npm run probe:tts-latency",
        },
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    OUT.mkdir(parents=True, exist_ok=True)
    REPORT_PATH.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0 if runs and runs[0]["pcm_bytes"] > 0 else 1


if __name__ == "__main__":
    sys.exit(main())
