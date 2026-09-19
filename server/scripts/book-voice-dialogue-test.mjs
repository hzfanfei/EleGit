import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLocalEnv } from "../src/env.js";
import { speakableText } from "../src/voice-call.js";

loadLocalEnv();

const base = `http://127.0.0.1:${process.env.WENXIANG_PORT || 8787}`;
const wxKey = String(process.env.WENXIANG_API_KEY || "").trim();
const outDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "test-output", "dialogue");

const questions = [
  "用朋友聊天的口气，一句话说清这本书讲啥。",
  "我现在这章最该记住的一点是什么？",
  "别写小论文， oral 回答：主角此刻 biggest 困境是啥？",
];

if (!wxKey) {
  console.error("WENXIANG_API_KEY missing");
  process.exit(1);
}

const headers = {
  "Content-Type": "application/json",
  "X-Wenxiang-Key": wxKey,
  Accept: "text/event-stream",
};

async function json(pathname) {
  const res = await fetch(`${base}${pathname}`, {
    headers: { ...headers, Accept: "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${pathname} ${res.status}: ${body.error || ""}`);
  return body;
}

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
  const spoken = speakableText(raw);
  const chars = [...spoken].length;
  const issues = [];
  if (chars > 120) issues.push("偏长");
  if (/[#*`>\[\]|]/.test(raw)) issues.push("含 markdown");
  if (/```/.test(raw)) issues.push("含代码块");
  if (/(首先|综上所述|总的来说|如下)/.test(spoken)) issues.push("书面套话");
  if (chars <= 90 && issues.length === 0) issues.push("长度像口语");
  return { chars, spoken, issues, raw };
}

async function voiceTurn(bookId, message, history = []) {
  const res = await fetch(`${base}/v1/books/voice-turn`, {
    method: "POST",
    headers,
    body: JSON.stringify({ bookId, message, history }),
  });
  if (!res.ok) {
    const err = await res.text();
    throw new Error(`voice-turn ${res.status}: ${err.slice(0, 300)}`);
  }
  const pcmChunks = [];
  let answer = "";
  let engine = "";
  let buffer = "";
  const decoder = new TextDecoder();
  for await (const piece of res.body) {
    buffer += decoder.decode(piece, { stream: true });
    const parts = buffer.split("\n\n");
    buffer = parts.pop() || "";
    for (const part of parts) {
      const dataLine = part.split("\n").find((l) => l.startsWith("data:"));
      if (!dataLine) continue;
      let event;
      try {
        event = JSON.parse(dataLine.slice(5).trim());
      } catch {
        continue;
      }
      if (event.type === "audio" && event.pcm) {
        pcmChunks.push(Buffer.from(event.pcm, "base64"));
      }
      if (event.type === "done") {
        answer = event.answer || answer;
        engine = event.engine || engine;
      }
      if (event.type === "error") {
        throw new Error(event.hint || event.code || "voice-turn error");
      }
    }
  }
  return { pcm: Buffer.concat(pcmChunks), answer, engine };
}

async function textChat(bookId, message) {
  const res = await fetch(`${base}/v1/books/chat`, {
    method: "POST",
    headers,
    body: JSON.stringify({ bookId, message, history: [] }),
  });
  if (!res.ok) throw new Error(`chat ${res.status}`);
  let answer = "";
  let buffer = "";
  const decoder = new TextDecoder();
  for await (const piece of res.body) {
    buffer += decoder.decode(piece, { stream: true });
    const parts = buffer.split("\n\n");
    buffer = parts.pop() || "";
    for (const part of parts) {
      const dataLine = part.split("\n").find((l) => l.startsWith("data:"));
      if (!dataLine) continue;
      let event;
      try {
        event = JSON.parse(dataLine.slice(5).trim());
      } catch {
        continue;
      }
      if (event.type === "delta" && event.text) answer += event.text;
      if (event.type === "done" && event.answer) answer = event.answer;
    }
  }
  return answer.trim();
}

try {
  await json("/health");
} catch {
  console.error("问象服务未启动。请在 server 目录 npm start 后再跑本脚本。");
  process.exit(1);
}

const status = await json("/v1/status");
if (!status.books?.ready) {
  console.error("问书 ACP 未就绪");
  process.exit(1);
}
if (!status.voice?.ready) {
  console.error("语音未配置");
  process.exit(1);
}

const { books } = await json("/v1/books");
const book = books?.[0];
if (!book) {
  console.error("书库为空");
  process.exit(1);
}

mkdirSync(outDir, { recursive: true });
console.log("Book:", book.title);
console.log("Output:", outDir);
console.log("");

const history = [];
for (let i = 0; i < questions.length; i += 1) {
  const q = questions[i];
  console.log(`--- Q${i + 1}: ${q}`);
  const t0 = performance.now();
  const { pcm, answer, engine } = await voiceTurn(book.id, q, history);
  const ms = Math.round(performance.now() - t0);
  const scored = scoreAnswer(answer);
  const wav = path.join(outDir, `turn-${i + 1}.wav`);
  if (pcm.length) writeFileSync(wav, pcmToWav(pcm));
  console.log(`  engine: ${engine}, latency: ${ms}ms, pcm: ${pcm.length} bytes`);
  console.log(`  原文 (${scored.chars} 字): ${scored.spoken}`);
  console.log(`  口语评分: ${scored.issues.join("，") || "—"}`);
  if (pcm.length) console.log(`  音频: ${wav}`);
  history.push({ role: "user", content: q }, { role: "assistant", content: answer });
  console.log("");
}

console.log("--- 对照：同一问题 文字问书 vs 快问快答 prompt ---");
const probe = "用一句话说，这本书的核心冲突是什么？";
const [textAns, voiceProbe] = await Promise.all([
  textChat(book.id, probe),
  voiceTurn(book.id, probe).then((r) => r.answer),
]);
const tScore = scoreAnswer(textAns);
const vScore = scoreAnswer(voiceProbe);
console.log(`文字问书 (${tScore.chars}字): ${tScore.spoken.slice(0, 160)}${tScore.chars > 160 ? "…" : ""}`);
console.log(`  → ${tScore.issues.join("，")}`);
console.log(`快问快答 (${vScore.chars}字): ${vScore.spoken}`);
console.log(`  → ${vScore.issues.join("，")}`);
