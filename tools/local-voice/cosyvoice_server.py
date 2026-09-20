"""Long-lived CosyVoice3 TTS worker (preload model + cached zero-shot spk)."""
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
DEFAULT_MODEL = "FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
DEFAULT_SPK = "wenxiang_default"
PROMPT_TEXT = (
    "You are a helpful assistant.<|endofprompt|>"
    "\u5e0c\u671b\u4f60\u4ee5\u540e\u80fd\u591f\u505a\u7684\u6bd4\u6211\u8fd8\u597d\u5456\u3002"
)

_state: dict[str, Any] = {"ready": False, "error": None, "device": "cpu", "load_ms": 0}
_cosy = None
_lock = threading.Lock()


def _init_model() -> None:
    global _cosy
    if not COSY.is_dir():
        raise RuntimeError(f"CosyVoice not found at {COSY}")

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
    spk_id = os.environ.get("COSYVOICE_SPK_ID", DEFAULT_SPK)
    prompt_wav = COSY / "asset" / "zero_shot_prompt.wav"
    if not prompt_wav.is_file():
        raise RuntimeError(f"Missing prompt wav: {prompt_wav}")

    t0 = time.perf_counter()
    _cosy = CosyVoice3(model_id, load_trt=False, fp16=(device == "cuda"))
    _cosy.add_zero_shot_spk(PROMPT_TEXT, str(prompt_wav), spk_id)
    _state["load_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    _state["model"] = model_id
    _state["spk_id"] = spk_id
    _state["sample_rate"] = int(getattr(_cosy, "sample_rate", 24000))
    _state["ready"] = True


def _synthesize(text: str) -> bytes:
    import numpy as np

    if _cosy is None:
        raise RuntimeError("model not loaded")
    spk_id = _state.get("spk_id", DEFAULT_SPK)
    chunks: list[bytes] = []
    for out in _cosy.inference_zero_shot(
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
        if not text:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "0")
            self.send_header("X-Sample-Rate", str(_state.get("sample_rate", 24000)))
            self.end_headers()
            return
        try:
            with _lock:
                pcm = _synthesize(text)
        except Exception as err:
            self._send_json(500, {"error": str(err)})
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(pcm)))
        self.send_header("X-Sample-Rate", str(_state.get("sample_rate", 24000)))
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
        f"http://{bind}:{port}\n"
    )
    server = ThreadingHTTPServer((bind, port), Handler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
