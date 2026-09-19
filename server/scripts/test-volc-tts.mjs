import { writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLocalEnv } from "../src/env.js";
import { resolveVoiceConfig } from "../src/voice-config.js";
import { volcTts } from "../src/voice-volc.js";

const envInfo = loadLocalEnv();
const text = process.argv.slice(2).join(" ").trim() || "你好，问书快问快答测试。";
const cfg = resolveVoiceConfig();

if (!cfg.ready || cfg.provider !== "volc") {
  console.error("Voice not configured. Set VOLC_APP_ID + VOLC_ACCESS_TOKEN or VOLC_API_KEY in .env");
  console.error("Env file:", envInfo.file, envInfo.loaded ? "(loaded)" : "(missing)");
  process.exit(1);
}

const volc = cfg.volc;
console.log("TTS test");
console.log("  env:", envInfo.file);
console.log("  url:", volc.ttsUrl);
console.log("  resource:", volc.ttsResourceId || "(v1 legacy)");
console.log("  voice:", volc.ttsVoice);
console.log(
  "  auth:",
  volc.apiKey ? "api-key" : volc.appId && volc.accessToken ? "app+token" : "incomplete",
);
console.log("  text:", text);

try {
  const pcm = await volcTts(volc, text);
  if (!pcm.length) {
    console.error("FAIL: empty audio buffer");
    process.exit(1);
  }
  const outDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "test-output");
  const wav = pcm16ToWav(pcm, 24000);
  const out = path.join(outDir, "volc-tts-test.wav");
  writeFileSync(out, wav);
  console.log(`OK: ${pcm.length} bytes PCM → ${out}`);
  console.log("Play the wav file to verify speech.");
} catch (err) {
  console.error("FAIL:", err.message);
  if (err.detail) console.error("Detail:", err.detail);
  if (err.code) console.error("Code:", err.code);
  process.exit(1);
}

function pcm16ToWav(pcm, sampleRate = 24000, channels = 1) {
  const byteRate = sampleRate * channels * 2;
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(channels, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(byteRate, 28);
  header.writeUInt16LE(channels * 2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}
