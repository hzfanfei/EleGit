"""Long-lived FunASR worker (preload Paraformer, PCM HTTP ASR)."""
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
DEFAULT_MODEL = "paraformer-zh"

_state: dict[str, Any] = {"ready": False, "error": None, "device": "cpu", "load_ms": 0}
_model = None
_lock = threading.Lock()


def _pick_device() -> str:
    import torch

    if not torch.cuda.is_available() or torch.cuda.device_count() < 1:
        return "cpu"
    try:
        torch.zeros(1, device="cuda:0")
        return "cuda:0"
    except RuntimeError:
        return "cpu"


def _init_model() -> None:
    global _model
    from funasr import AutoModel

    device = _pick_device()
    _state["device"] = device
    model_id = os.environ.get("FUNASR_MODEL_ID", DEFAULT_MODEL)
    t0 = time.perf_counter()
    _model = AutoModel(model=model_id, device=device, disable_update=True)
    _state["load_ms"] = round((time.perf_counter() - t0) * 1000, 1)
    _state["model"] = model_id
    _state["sample_rate"] = 16000
    _state["ready"] = True


def _transcribe_pcm(pcm: bytes) -> str:
    import numpy as np

    if _model is None:
        raise RuntimeError("model not loaded")
    if not pcm:
        return ""
    samples = np.frombuffer(pcm, dtype=np.int16)
    if samples.size == 0:
        return ""
    audio = samples.astype(np.float32) / 32768.0
    result = _model.generate(input=audio, batch_size=1)
    text = ""
    if result and isinstance(result, list):
        item = result[0]
        text = str(item.get("text", "") if isinstance(item, dict) else item)
    return text.strip()


class Handler(BaseHTTPRequestHandler):
    server_version = "WenxiangFunASR/1.0"

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
        if self.path.rstrip("/") != "/v1/asr":
            self.send_error(404)
            return
        if not _state.get("ready"):
            self._send_json(503, {"error": "not ready", **_state})
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        pcm = self.rfile.read(length) if length else b""
        try:
            with _lock:
                text = _transcribe_pcm(pcm)
        except Exception as err:
            self._send_json(500, {"error": str(err)})
            return
        final = self.headers.get("X-Final", "1") != "0"
        self._send_json(200, {"text": text, "final": final})


def main() -> int:
    port = int(os.environ.get("FUNASR_ASR_PORT", "18788"))
    bind = os.environ.get("FUNASR_ASR_BIND", "127.0.0.1")
    try:
        _init_model()
    except Exception as err:
        _state["error"] = str(err)
        sys.stderr.write(f"FunASR preload failed: {err}\n")
        return 1
    sys.stderr.write(
        f"FunASR ready device={_state['device']} load_ms={_state['load_ms']} "
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
