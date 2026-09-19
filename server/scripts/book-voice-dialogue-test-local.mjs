import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createSessionStore } from "../src/acp.js";
import { createBookAskIterator } from "../src/book-voice-turn.js";
import { loadLocalEnv } from "../src/env.js";
import { loadStore } from "../src/store.js";
import { listBooks, resolveBook, ensureBookMaterialized } from "../src/books.js";
import { runVoiceTurn } from "../src/voice-call.js";
import { resolveVoiceConfig } from "../src/voice-config.js";
import { createVoiceProviders } from "../src/voice-ws.js";
import { volcTts } from "../src/voice-volc.js";

loadLocalEnv();

const outDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "test-output", "dialogue");
const questions = [
  "用朋友聊天的口气，一句话说清这本书讲啥。",
  "我现在这章最该记住的一点是什么？",
  "别写小论文，口头回答：经理人最容易踩的坑是什么？",
];

function pcmToWav(pcm, sampleRate = 24000) {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + pcm.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(pcm.length, 40);
  return Buffer.concat([header, pcm]);
}

function scoreAnswer(text) {
  const raw = String(text || "").trim();
  const spoken = raw;
  const chars = [...spoken].length;
  const issues = [];
  if (chars > 120) issues.push("偏长");
  if (chars < 15) issues.push("过短");
  if (/[#*`>\[\]|]/.test(raw)) issues.push("含 markdown");
  if (/```/.test(raw)) issues.push("含代码块");
  if (/(首先|综上所述|总的来说|如下|以下是)/.test(spoken)) issues.push("书面套话");
  if (chars <= 95 && !issues.includes("含 markdown")) issues.push("长度偏口语");
  return { chars, spoken, issues, raw };
}

const voiceConfig = resolveVoiceConfig();
if (!voiceConfig.ready || !voiceConfig.volc) {
  console.error("火山语音未配置");
  process.exit(1);
}
const providers = createVoiceProviders(voiceConfig);
const tts = providers.tts || ((text, signal) => volcTts(voiceConfig.volc, text, signal));

const store = await loadStore();
const bookSessions = createSessionStore();
const catalog = await listBooks(store.config.workspaceRoot);
const books = catalog.books || [];
if (!books.length) {
  console.error("书库为空");
  process.exit(1);
}
const picked = books[0];
const book = await resolveBook(store.config.workspaceRoot, picked.id);
const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
const session = bookSessions.resolveForChat("local", book.id, "");
await bookSessions.warm(session, materialized.cacheDir).catch(() => {});

mkdirSync(outDir, { recursive: true });
console.log("Book:", book.title);
console.log("Voice:", voiceConfig.volc.ttsVoice);
console.log("Output:", outDir);
console.log("");

const history = [];
for (let i = 0; i < questions.length; i += 1) {
  const q = questions[i];
  console.log(`--- Q${i + 1}: ${q}`);
  const pcmChunks = [];
  const t0 = performance.now();
  const ask = createBookAskIterator({
    book,
    materialized,
    session,
    bookSessions,
    chapter: "",
    history,
    signal: new AbortController().signal,
  });
  const result = await runVoiceTurn({
    question: q,
    ask,
    tts,
    onAudio: async (buf) => {
      pcmChunks.push(Buffer.from(buf));
    },
  });
  const ms = Math.round(performance.now() - t0);
  const scored = scoreAnswer(result.answer);
  const pcm = Buffer.concat(pcmChunks);
  const wav = path.join(outDir, `turn-${i + 1}.wav`);
  if (pcm.length) writeFileSync(wav, pcmToWav(pcm));
  console.log(`  engine: ${result.engine}, latency: ${ms}ms`);
  console.log(`  可朗读 (${scored.chars} 字): ${scored.spoken}`);
  console.log(`  评估: ${scored.issues.join("，") || "—"}`);
  if (pcm.length) console.log(`  音频: ${wav}`);
  history.push({ role: "user", content: q }, { role: "assistant", content: result.answer });
  console.log("");
}

console.log("请本地播放 test-output/dialogue/turn-*.wav，听是否像真人简短对话。");
