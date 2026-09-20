"""Ensure zero-shot prompt wavs exist (Edge TTS for zh-CN reference clips)."""
from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CATALOG = ROOT / "cosyvoice_voices.json"


def _load_catalog() -> list[dict]:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    voices = data.get("voices")
    if not isinstance(voices, list):
        raise RuntimeError(f"Invalid catalog: {CATALOG}")
    return voices


async def _edge_save(voice: str, line: str, out: Path) -> None:
    import edge_tts

    out.parent.mkdir(parents=True, exist_ok=True)
    communicate = edge_tts.Communicate(line, voice)
    await communicate.save(str(out))


def ensure_all(root: Path | None = None) -> list[str]:
    base = root or ROOT
    created: list[str] = []
    for entry in _load_catalog():
        rel = entry.get("prompt_wav")
        if not rel:
            continue
        wav = base / str(rel)
        if wav.is_file() and wav.stat().st_size > 1000:
            continue
        edge_voice = entry.get("edge_voice")
        edge_line = entry.get("edge_line")
        if not edge_voice or not edge_line:
            if not wav.is_file():
                raise RuntimeError(f"Missing prompt wav: {wav}")
            continue
        asyncio.run(_edge_save(str(edge_voice), str(edge_line), wav))
        created.append(str(wav.relative_to(base)))
    return created


def main() -> int:
    try:
        made = ensure_all()
    except Exception as err:
        print(f"ensure_cosyvoice_prompts failed: {err}", file=sys.stderr)
        return 1
    if made:
        print("created:", ", ".join(made))
    else:
        print("all cosyvoice prompt wavs present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
