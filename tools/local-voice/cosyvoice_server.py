"""Long-lived CosyVoice3 TTS worker (preload model + cached zero-shot speakers)."""
from __future__ import annotations

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
COSY = ROOT / "CosyVoice"
CATALOG = ROOT / "cosyvoice_voices.json"
DEFAULT_MODEL = "FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
DEFAULT_SPK = "zh_female_xiaohe_uranus_bigtts"

_state: dict[str, Any] = {"ready": False, "error": None, "device": "cpu", "load_ms": 0}
_cosy = None
_lock = threading.Lock()
_speakers: dict[str, dict[str, str]] = {}


def _load_catalog() -> list[dict[str, Any]]:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    voices = data.get("voices")
    if not isinstance(voices, list) or not voices:
        raise RuntimeError(f"Invalid voice catalog: {CATALOG}")
    return voices


def _init_model() -> None:
    global _cosy
    if not COSY.is_dir():
        raise RuntimeError(f"CosyVoice not found at {COSY}")

    from ensure_cosyvoice_prompts import ensure_all

    ensure_all(ROOT, auto_generate=False)

    sys.path.insert(0, str(COSY))
    sys.path.insert(0, str(COSY / "third_party" / "Matcha-TTS"))

    from test_cosyvoice import _hide_gpu_if_cuda_broken, _patch_torchaudio_load

    _hide_gpu_if_cuda_broken()
    _patch_torchaudio_load()

    import torch
    from cosyvoice.cli.cosyvoice import CosyVoice3

    device = (
        "cuda"
        if torch.cuda.is_available() and torch.cuda.device_count() > 0
        else "cpu"
    )
    _state["device"] = device

    model_id = os.environ.get("COSYVOICE_MODEL_ID", DEFAULT_MODEL)
    t0 = time.perf_counter()
    _cosy = CosyVoice3(model_id, load_trt=False, fp16=(device == "cuda"))

    _speakers.clear()
    for entry in _load_catalog():
        spk_id = str(entry.get("id") or "").strip()
        prompt_text = str(entry.get("prompt_text") or "").strip()
        rel_wav = str(entry.get("prompt_wav") or "").strip()
        if not spk_id or not prompt_text or not rel_wav:
            continue
        prompt_wav = (ROOT / rel_wav).resolve()
        if not prompt_wav.is_file():
            sys.stderr.write(f"[cosyvoice] skip missing prompt: {prompt_wav}\n")
            continue
        _cosy.add_zero_shot_spk(prompt_text, str(prompt_wav), spk_id)
        _speakers[spk_id] = {
            "id": spk_id,
            "name": str(entry.get("name") or spk_id),
            "scene": str(entry.get("scene") or ""),
        }

    if not _speakers:
        raise RuntimeError("No CosyVoice speakers registered (check cosyvoice_voices.json)")

    default_spk = os.environ.get("COSYVOICE_SPK_ID", DEFAULT_SPK)
    if default_spk not in _speakers:
        default_spk = next(iter(_speakers.keys()))

    _state["load_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    _state["model"] = model_id
    _state["default_spk"] = default_spk
    _state["spk_id"] = default_spk
    _state["speakers"] = list(_speakers.values())
    _state["speaker_ids"] = list(_speakers.keys())
    _state["sample_rate"] = int(getattr(_cosy, "sample_rate", 24000))
    _state["ready"] = True


def _resolve_spk(spk_id: str | None) -> str:
    raw = str(spk_id or _state.get("default_spk") or DEFAULT_SPK).strip()
    if raw in _speakers:
        return raw
    fallback = str(_state.get("default_spk") or next(iter(_speakers.keys())))
    return fallback


def _synthesize(text: str, spk_id: str) -> bytes:
    import numpy as np

    if _cosy is None:
        raise RuntimeError("model not loaded")
    spk = _resolve_spk(spk_id)
    chunks: list[bytes] = []
    for out in _cosy.inference_zero_shot(
        text,
        "",
        "",
        zero_shot_spk_id=spk,
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
    return b"".join(chunks)


class Handler(BaseHTTPRequestHandler):
    server_version = "WenxiangCosyVoice/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, code: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path.rstrip("/") == "/health":
            self._send_json(200 if _state.get("ready") else 503, dict(_state))
            return
        self.send_error(404)

    def do_POST(self) -> None:
        if self.path.rstrip("/") != "/v1/tts":
            self.send_error(404)
            return
        if not _state.get("ready"):
            self._send_json(503, {"error": "not ready", **_state})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid json"})
            return
        text = str(payload.get("text") or "").strip()
        spk_id = str(payload.get("spk_id") or payload.get("ttsVoice") or "").strip()
        if not text:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "0")
            self.send_header("X-Sample-Rate", str(_state.get("sample_rate", 24000)))
            self.end_headers()
            return
        try:
            with _lock:
                pcm = _synthesize(text, spk_id)
        except Exception as err:
            self._send_json(500, {"error": str(err)})
            return
        used = _resolve_spk(spk_id)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(pcm)))
        self.send_header("X-Sample-Rate", str(_state.get("sample_rate", 24000)))
        self.send_header("X-CosyVoice-Spk", used)
        self.end_headers()
        self.wfile.write(pcm)


def main() -> int:
    port = int(os.environ.get("COSYVOICE_TTS_PORT", "18787"))
    bind = os.environ.get("COSYVOICE_TTS_BIND", "127.0.0.1")
    try:
        _init_model()
    except Exception as err:
        _state["error"] = str(err)
        sys.stderr.write(f"CosyVoice preload failed: {err}\n")
        return 1
    sys.stderr.write(
        f"CosyVoice ready device={_state['device']} load_ms={_state['load_ms']} "
        f"speakers={len(_speakers)} http://{bind}:{port}\n"
    )
    server = ThreadingHTTPServer((bind, port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
