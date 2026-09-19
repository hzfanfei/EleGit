/**
 * Compare book Q&A answers: composer-2.5-fast vs auto (same questions, fresh ACP per model).
 *
 * Usage (from repo root):
 *   node server/scripts/book-model-compare.mjs
 *
 * Requires: Cursor agent CLI logged in, EPUB in books dir, .env with keys as usual.
 */
import { writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  acpModelId,
  createSessionStore,
  detectCursorEngine,
} from "../src/acp.js";
import { createBookAskIterator } from "../src/book-voice-turn.js";
import { loadLocalEnv } from "../src/env.js";
import { loadStore } from "../src/store.js";
import { listBooks, resolveBook, ensureBookMaterialized } from "../src/books.js";

loadLocalEnv();

const MODELS = String(process.env.WENXIANG_COMPARE_MODELS || "composer-2.5-fast,auto")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean);

const QUESTIONS = [
  "用朋友聊天的口气，一句话说清这本书讲啥。",
  "别写小论文，口头回答：这一章里最重要的一件事是什么？",
];

function scoreAnswer(text) {
  const raw = String(text || "").trim();
  const spoken = raw;
  const chars = [...spoken].length;
  const issues = [];
  if (chars > 120) issues.push("偏长");
  if (chars < 12) issues.push("过短");
  if (/[#*`>\[\]|]/.test(raw)) issues.push("markdown");
  if (/```/.test(raw)) issues.push("代码块");
  if (/(首先|综上所述|总的来说|如下|以下是)/.test(spoken)) issues.push("书面套话");
  if (/^(?:让我|我来|我先|正在|查完|分析)/.test(spoken)) issues.push("过程句");
  return { chars, spoken, issues, raw };
}

async function askBook({ model, question, book, materialized, cacheDir, chapter }) {
  const prev = process.env.WENXIANG_CURSOR_MODEL;
  process.env.WENXIANG_CURSOR_MODEL = model;
  const effective = acpModelId();
  const owner = `model-bench-${effective.replace(/[^a-zA-Z0-9._-]+/g, "_")}`;
  const bookSessions = createSessionStore();
  const created = bookSessions.create(owner, book.id);
  const session = bookSessions.resolveForChat(owner, book.id, created.id);
  const signal = new AbortController().signal;

  await bookSessions.warm(session, cacheDir).catch(() => {});

  const ask = createBookAskIterator({
    book,
    materialized,
    session,
    bookSessions,
    chapter,
    history: [],
    signal,
  });

  let ttftMs = null;
  let answer = "";
  let engine = "";
  const t0 = performance.now();

  try {
    for await (const event of ask(question, signal)) {
      if (event.type === "start") engine = event.engine || engine;
      if (event.type === "delta" && event.text) {
        if (ttftMs == null) ttftMs = performance.now() - t0;
        answer += event.text;
      }
      if (event.type === "done") {
        engine = event.engine || engine;
        if (event.answer && !answer) answer = event.answer;
      }
    }
  } finally {
    if (prev !== undefined) process.env.WENXIANG_CURSOR_MODEL = prev;
    else delete process.env.WENXIANG_CURSOR_MODEL;
    await bookSessions.close(owner, book.id, session.id).catch(() => {});
  }

  const totalMs = performance.now() - t0;
  const scored = scoreAnswer(answer);

  return {
    model: effective,
    engine,
    ttftMs: ttftMs == null ? null : Math.round(ttftMs),
    totalMs: Math.round(totalMs),
    answer: answer.trim(),
    voiceText: answer.trim(),
    scored,
  };
}

function pad(s, n) {
  const t = String(s ?? "");
  return t.length >= n ? t : t + " ".repeat(n - t.length);
}

const acp = detectCursorEngine();
if (!acp) {
  console.error("Cursor ACP CLI 未找到 — 请安装 agent 并 login。");
  process.exit(1);
}

const store = await loadStore();
const catalog = await listBooks(store.config.workspaceRoot);
const books = catalog.books || [];
if (!books.length) {
  console.error("书库为空，请先放入 EPUB。");
  process.exit(1);
}

const picked = books[0];
const book = await resolveBook(store.config.workspaceRoot, picked.id);
const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
const chapter = "";

console.log("=== 问书模型对比（ACP 文字回答，无 TTS）===");
console.log("书:", book.title);
console.log("章 hint:", chapter || "(未取到目录)");
console.log("默认模型 env:", acpModelId());
console.log("对比:", MODELS.join(" vs "));
console.log("");

const rows = [];

for (const q of QUESTIONS) {
  console.log(`--- ${q}`);
  for (const model of MODELS) {
    process.stdout.write(`  [${model}] 请求中… `);
    try {
      const row = await askBook({
        model,
        question: q,
        book,
        materialized,
        cacheDir: materialized.cacheDir,
        chapter,
      });
      rows.push({ question: q, ...row });
      console.log(
        `TTFT ${row.ttftMs ?? "n/a"}ms | 总 ${row.totalMs}ms | ${row.scored.chars} 字 | 问题: ${row.scored.issues.join("，") || "—"}`,
      );
      console.log(`    口语: ${row.voiceText.slice(0, 160)}${row.voiceText.length > 160 ? "…" : ""}`);
    } catch (err) {
      console.log(`失败: ${err.message || err}`);
      rows.push({
        question: q,
        model,
        error: String(err.message || err),
      });
    }
  }
  console.log("");
}

console.log("=== 汇总表 ===");
console.log(
  pad("模型", 22) +
    pad("TTFT(ms)", 12) +
    pad("总(ms)", 10) +
    pad("字", 6) +
    "评估",
);
for (const model of MODELS) {
  const subset = rows.filter((r) => r.model === model && !r.error);
  if (!subset.length) {
    console.log(pad(model, 22) + "(无成功样本)");
    continue;
  }
  const avgTtft = Math.round(
    subset.reduce((s, r) => s + (r.ttftMs || 0), 0) / subset.length,
  );
  const avgTotal = Math.round(subset.reduce((s, r) => s + r.totalMs, 0) / subset.length);
  const avgChars = Math.round(subset.reduce((s, r) => s + r.scored.chars, 0) / subset.length);
  const issues = [...new Set(subset.flatMap((r) => r.scored.issues))];
  console.log(
    pad(model, 22) +
      pad(String(avgTtft), 12) +
      pad(String(avgTotal), 10) +
      pad(String(avgChars), 6) +
      (issues.length ? issues.join("，") : "—"),
  );
}

const outDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "test-output");
mkdirSync(outDir, { recursive: true });
const outFile = path.join(outDir, "book-model-compare.json");
writeFileSync(outFile, JSON.stringify({ book: book.title, chapter, rows }, null, 2), "utf8");
console.log("");
console.log("详细结果:", outFile);
