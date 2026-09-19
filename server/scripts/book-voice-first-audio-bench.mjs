/**
 * 真机快问：首包 audio (SSE) 与各阶段耗时账本。
 * Usage: node scripts/book-voice-first-audio-bench.mjs [--book-id ID] [--message "…"]
 */
import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLocalEnv } from "../src/env.js";
import {
  BOOK_VOICE_CLIENT_WAITS_FOR_DONE,
  BOOK_VOICE_SPEAK_STRATEGY,
  diagnoseBookVoiceLatency,
  formatLatencyDiagnosis,
} from "../src/book-voice-latency.js";

loadLocalEnv();

const base = `http://127.0.0.1:${process.env.WENXIANG_PORT || 8787}`;
const wxKey = String(process.env.WENXIANG_API_KEY || "").trim();
const args = process.argv.slice(2);
const bookIdArg = args.includes("--book-id") ? args[args.indexOf("--book-id") + 1] : "";
const messageArg = args.includes("--message")
  ? args[args.indexOf("--message") + 1]
  : "用朋友聊天的口气，一句话说清这本书讲啥。";

if (!wxKey) {
  console.error("WENXIANG_API_KEY missing");
  process.exit(1);
}

const headers = {
  "Content-Type": "application/json",
  "X-Wenxiang-Key": wxKey,
  Accept: "text/event-stream",
};

async function json(pathname, init = {}) {
  const res = await fetch(`${base}${pathname}`, {
    ...init,
    headers: { "X-Wenxiang-Key": wxKey, Accept: "application/json", ...init.headers },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${pathname} ${res.status}: ${body.error || ""}`);
  return body;
}

function mark(markers, phase, t0, at = performance.now()) {
  if (markers.some((m) => m.phase === phase)) return;
  markers.push({ phase, atMs: at - t0 });
}

async function benchVoiceTurn({ bookId, message, chapter = "" }) {
  const t0 = performance.now();
  const markers = [];
  mark(markers, "turn_start", t0, t0);

  const res = await fetch(`${base}/v1/books/voice-turn`, {
    method: "POST",
    headers,
    body: JSON.stringify({ bookId, message, history: [], chapter }),
  });
  mark(markers, "http_response", t0);

  if (!res.ok) {
    const err = await res.text();
    throw new Error(`voice-turn ${res.status}: ${err.slice(0, 400)}`);
  }

  let answer = "";
  let engine = "";
  let audioEvents = 0;
  let pcmBytes = 0;
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
      const now = performance.now();
      if (event.type === "meta") mark(markers, "sse_meta", t0, now);
      if (event.type === "state") {
        if (event.phase === "connect") mark(markers, "sse_state_connect", t0, now);
        if (event.phase === "think") {
          mark(markers, "sse_state_think", t0, now);
          mark(markers, "ask_start", t0, now);
        }
        if (event.phase === "speak") mark(markers, "sse_state_speak", t0, now);
      }
      if (event.type === "audio" && event.pcm) {
        audioEvents += 1;
        pcmBytes += Buffer.from(event.pcm, "base64").length;
        mark(markers, "first_audio", t0, now);
      }
      if (event.type === "done") {
        mark(markers, "turn_done", t0, now);
        answer = event.answer || answer;
        engine = event.engine || engine;
      }
      if (event.type === "error") {
        throw new Error(event.hint || event.code || "voice-turn error");
      }
    }
  }

  if (!markers.some((m) => m.phase === "turn_done")) {
    mark(markers, "turn_done", t0);
  }

  const diag = diagnoseBookVoiceLatency(markers, {
    speakStrategy: BOOK_VOICE_SPEAK_STRATEGY,
    clientWaitsForDone: BOOK_VOICE_CLIENT_WAITS_FOR_DONE,
  });

  const rel = (phase) => {
    const hit = markers.find((m) => m.phase === phase);
    return hit ? Math.round(hit.atMs) : null;
  };

  const ledger = {
    配置: {
      speakStrategy: BOOK_VOICE_SPEAK_STRATEGY,
      app等done再播: BOOK_VOICE_CLIENT_WAITS_FOR_DONE,
      用户感知首声: BOOK_VOICE_CLIENT_WAITS_FOR_DONE ? "turn_done" : "first_audio",
    },
    问题: message,
    bookId,
    engine,
    首包audio_ms: rel("first_audio"),
    回合结束_ms: rel("turn_done"),
    用户感知首声_ms: BOOK_VOICE_CLIENT_WAITS_FOR_DONE ? rel("turn_done") : rel("first_audio"),
    audio事件数: audioEvents,
    pcm总字节: pcmBytes,
    答案字数: [...String(answer || "")].length,
    阶段_ms: {
      请求到HTTP响应: rel("http_response"),
      HTTP到meta: rel("sse_meta") != null && rel("http_response") != null ? rel("sse_meta") - rel("http_response") : null,
      meta到进入思考: rel("sse_state_think") != null && rel("sse_meta") != null ? rel("sse_state_think") - rel("sse_meta") : null,
      思考到首包audio_ACP加首段TTS: rel("first_audio") != null && rel("ask_start") != null ? rel("first_audio") - rel("ask_start") : null,
      首包audio到进入speak状态: rel("sse_state_speak") != null && rel("first_audio") != null ? rel("sse_state_speak") - rel("first_audio") : null,
      首包audio到回合结束: rel("turn_done") != null && rel("first_audio") != null ? rel("turn_done") - rel("first_audio") : null,
    },
    诊断分桶_ms: diag.buckets,
    主要瓶颈: diag.dominant,
    时间线: markers.map((m) => ({ phase: m.phase, ms: Math.round(m.atMs) })),
  };

  return { ledger, answer: String(answer || "").trim(), diag };
}

try {
  await json("/health");
} catch {
  console.error("问象服务未启动。cd server && npm start");
  process.exit(1);
}

const status = await json("/v1/status");
if (!status.books?.ready || !status.voice?.ready) {
  console.error("问书或语音未就绪", status);
  process.exit(1);
}

const { books } = await json("/v1/books");
const book = bookIdArg ? books?.find((b) => b.id === bookIdArg) : books?.[0];
if (!book) {
  console.error("找不到书");
  process.exit(1);
}

console.log("Book:", book.title);
console.log("");

const { ledger, answer, diag } = await benchVoiceTurn({
  bookId: book.id,
  message: messageArg,
});

console.log("=== 快问首音 · 时间消耗账本（真机 SSE）===");
console.log(JSON.stringify(ledger, null, 2));
console.log("");
console.log(formatLatencyDiagnosis(diag));
console.log("");
console.log("答案摘要:", answer.slice(0, 200) + (answer.length > 200 ? "…" : ""));

const outDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "test-output");
mkdirSync(outDir, { recursive: true });
const outPath = path.join(outDir, "book-voice-first-audio-bench.json");
writeFileSync(outPath, `${JSON.stringify({ at: new Date().toISOString(), ledger, answer }, null, 2)}\n`);
console.log("");
console.log("已写入:", outPath);
