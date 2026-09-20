"""Ensure CosyVoice zero-shot prompt wavs exist (generated via Volc TTS, not Edge)."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CATALOG = ROOT / "cosyvoice_voices.json"
GENERATOR = ROOT / "generate-cosyvoice-prompts-volc.mjs"


def _load_catalog() -> list[dict]:
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    voices = data.get("voices")
    if not isinstance(voices, list):
        raise RuntimeError(f"Invalid catalog: {CATALOG}")
    return voices


def missing_prompts(base: Path | None = None) -> list[str]:
    root = base or ROOT
    missing: list[str] = []
    for entry in _load_catalog():
        rel = entry.get("prompt_wav")
        if not rel:
            continue
        wav = root / str(rel)
        if not wav.is_file() or wav.stat().st_size < 1000:
            missing.append(str(wav.relative_to(root)))
    return missing


def ensure_all(root: Path | None = None, *, auto_generate: bool = True) -> list[str]:
    """Return list of prompt paths still missing after optional Volc generation."""
    base = root or ROOT
    gap = missing_prompts(base)
    if not gap:
        return []
    if not auto_generate or not GENERATOR.is_file():
        return gap
    node = "node"
    subprocess.run(
        [node, str(GENERATOR)],
        cwd=str(ROOT),
        check=False,
    )
    return missing_prompts(base)


def main() -> int:
    try:
        still = ensure_all(auto_generate=True)
    except Exception as err:
        print(f"ensure_cosyvoice_prompts failed: {err}", file=sys.stderr)
        return 1
    if still:
        print("missing prompts (run: node tools/local-voice/generate-cosyvoice-prompts-volc.mjs):", file=sys.stderr)
        for p in still:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print("all cosyvoice prompt wavs present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
