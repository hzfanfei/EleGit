/**
 * Rewrite cosyvoice_voices.json from server seed-tts-2.0 list (same ids/names/scenes as Volc UI).
 * Prompt wavs are generated separately via generate-cosyvoice-prompts-volc.mjs.
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { VOLC_TTS_VOICES } from "../../server/src/volc-tts-voices.js";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const CATALOG = path.join(ROOT, "cosyvoice_voices.json");
const PROMPT_PREFIX = "You are a helpful assistant.<|endofprompt|>";

function spokenLine(name) {
  const short = String(name).replace(/\s*2\.0\s*$/, "").trim();
  return `你好，我是${short}，这是问象 CosyVoice 的参考语音。`;
}

const voices = VOLC_TTS_VOICES.map((v) => {
  const line = spokenLine(v.name);
  return {
    id: v.id,
    name: v.name,
    scene: v.scene,
    prompt_text: `${PROMPT_PREFIX}${line}`,
    prompt_wav: `voices/prompts/${v.id}.wav`,
    volc_speaker: v.id,
  };
});

fs.writeFileSync(CATALOG, `${JSON.stringify({ voices }, null, 2)}\n`, "utf8");
console.log(`Wrote ${voices.length} voices to ${CATALOG}`);
