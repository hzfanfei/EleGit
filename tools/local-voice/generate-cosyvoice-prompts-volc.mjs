/**
 * Synthesize CosyVoice zero-shot reference clips via Volc seed-tts-2.0 (one wav per catalog entry).
 * Requires Volc credentials in repo .env (same as companion).
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLocalEnv } from "../../server/src/env.js";
import { resolveVoiceConfig } from "../../server/src/voice-config.js";
import { volcTts } from "../../server/src/voice-volc.js";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const CATALOG = path.join(ROOT, "cosyvoice_voices.json");
const PROMPT_PREFIX = "You are a helpful assistant.<|endofprompt|>";

function parseArgs(argv) {
  return { force: argv.includes("--force"), only: argv.find((a) => a.startsWith("--only="))?.slice(7) };
}

function resamplePcmS16le(pcm, fromRate, toRate) {
  const inSamples = pcm.length / 2;
  if (inSamples === 0) return Buffer.alloc(0);
  const outSamples = Math.max(1, Math.round((inSamples * toRate) / fromRate));
  const out = Buffer.alloc(outSamples * 2);
  for (let i = 0; i < outSamples; i++) {
    const srcPos = (i * fromRate) / toRate;
    const i0 = Math.min(inSamples - 1, Math.floor(srcPos));
    const i1 = Math.min(inSamples - 1, i0 + 1);
    const frac = srcPos - i0;
    const s0 = pcm.readInt16LE(i0 * 2);
    const s1 = pcm.readInt16LE(i1 * 2);
    const sample = Math.round(s0 + (s1 - s0) * frac);
    out.writeInt16LE(Math.max(-32768, Math.min(32767, sample)), i * 2);
  }
  return out;
}

function writeWav16kMono(pcm24, outPath) {
  const pcm16 = resamplePcmS16le(pcm24, 24000, 16000);
  const dataSize = pcm16.length;
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + dataSize, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(16000, 24);
  header.writeUInt32LE(32000, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(dataSize, 40);
  fs.mkdirSync(path.dirname(outPath), { recursive: true });
  fs.writeFileSync(outPath, Buffer.concat([header, pcm16]));
}

function lineFromPromptText(promptText) {
  const raw = String(promptText || "");
  const marker = "<|endofprompt|>";
  const idx = raw.indexOf(marker);
  if (idx >= 0) return raw.slice(idx + marker.length).trim();
  return raw.trim();
}

async function main() {
  const { force, only } = parseArgs(process.argv.slice(2));
  loadLocalEnv();
  const cfg = resolveVoiceConfig();
  if (!cfg.ready || !cfg.volc) {
    console.error("Volc TTS not configured. Set VOLC_APP_ID + VOLC_ACCESS_TOKEN (or VOLC_API_KEY) in .env");
    process.exit(1);
  }
  const data = JSON.parse(fs.readFileSync(CATALOG, "utf8"));
  const voices = Array.isArray(data.voices) ? data.voices : [];
  let ok = 0;
  let skipped = 0;
  for (const entry of voices) {
    const id = String(entry.id || "").trim();
    if (only && id !== only) continue;
    const rel = String(entry.prompt_wav || "");
    const out = path.join(ROOT, rel);
    if (!force && fs.existsSync(out) && fs.statSync(out).size > 2000) {
      skipped += 1;
      continue;
    }
    const speaker = String(entry.volc_speaker || entry.id || "").trim();
    const spoken = lineFromPromptText(entry.prompt_text);
    if (!spoken) {
      console.error(`skip ${id}: empty prompt line`);
      continue;
    }
    process.stdout.write(`Volc TTS ${speaker} … `);
    const volc = { ...cfg.volc, ttsVoice: speaker, ttsFormat: "pcm" };
    const pcm = await volcTts(volc, spoken);
    if (!pcm?.length) {
      console.error("empty audio");
      continue;
    }
    writeWav16kMono(pcm, out);
    console.log(`${path.relative(ROOT, out)} (${pcm.length} B pcm)`);
    ok += 1;
    await new Promise((r) => setTimeout(r, 350));
  }
  console.log(`Done: ${ok} generated, ${skipped} skipped (existing).`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
