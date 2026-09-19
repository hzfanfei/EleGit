/**
 * Same book cwd + same prompt: ACP (session/prompt) vs Agent CLI (-p stream-json).
 * Usage: node scripts/book-acp-vs-cli-bench.mjs [--message "..."]
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import readline from "node:readline";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  acpModelId,
  buildBookAcpPrompt,
  createSessionStore,
  detectCursorEngine,
} from "../src/acp.js";
import { createBookAskIterator } from "../src/book-voice-turn.js";
import { loadLocalEnv } from "../src/env.js";
import { loadStore } from "../src/store.js";
import { listBooks, resolveBook, ensureBookMaterialized, formatBookAcpContext } from "../src/books.js";

loadLocalEnv();

const args = process.argv.slice(2);
const messageArg = args.includes("--message")
  ? args[args.indexOf("--message") + 1]
  : "用朋友聊天的口气，一句话说清这本书讲啥。";

function stripAcpTail(argv) {
  const copy = [...argv];
  while (copy.length) {
    const tail = copy[copy.length - 1];
    if (tail === "acp") {
      copy.pop();
      continue;
    }
    if (tail === "agent" && copy.length > 1) {
      copy.pop();
      continue;
    }
    break;
  }
  return copy;
}

function extractAssistantPiece(obj) {
  if (obj?.type !== "assistant") return "";
  const parts = obj?.message?.content;
  if (!Array.isArray(parts)) return "";
  return parts
    .filter((p) => p?.type === "text" && p.text)
    .map((p) => String(p.text))
    .join("");
}

async function runAcp({ question, book, materialized, cacheDir, chapter, promptText }) {
  const owner = "acp-vs-cli-bench-acp";
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

  let ttftVisibleMs = null;
  let answer = "";
  const t0 = performance.now();

  try {
    for await (const event of ask(question, signal)) {
      if (event.type === "delta" && event.text) {
        if (ttftVisibleMs == null) ttftVisibleMs = performance.now() - t0;
        answer += event.text;
      }
      if (event.type === "done" && event.answer && !answer) answer = event.answer;
    }
  } finally {
    await bookSessions.close(owner, book.id, session.id).catch(() => {});
  }

  return {
    transport: "acp",
    ttftVisibleMs: ttftVisibleMs == null ? null : Math.round(ttftVisibleMs),
    totalMs: Math.round(performance.now() - t0),
    answer: answer.trim(),
    promptChars: promptText.length,
  };
}

function runAgentCli({ cwd, prompt, timeoutMs = 600_000 }) {
  const engine = detectCursorEngine();
  if (!engine) throw new Error("Cursor agent CLI not found");

  const cliArgs = [
    ...stripAcpTail(engine.args),
    "-p",
    "--mode",
    "ask",
    "--workspace",
    cwd,
    "--output-format",
    "stream-json",
    "--stream-partial-output",
    "--trust",
    prompt,
  ];

  const useShell = process.platform === "win32" && /\.(cmd|bat)$/i.test(engine.path);

  return new Promise((resolve, reject) => {
    const t0 = performance.now();
    let ttftAssistantMs = null;
    let ttftThinkingMs = null;
    let answer = "";
    let stderr = "";
    const child = spawn(engine.path, cliArgs, {
      cwd,
      stdio: ["ignore", "pipe", "pipe"],
      windowsHide: true,
      shell: useShell,
      env: { ...process.env },
    });

    const timer = setTimeout(() => {
      child.kill("SIGTERM");
      reject(new Error(`CLI timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    child.stderr.on("data", (c) => {
      stderr += c.toString();
    });

    child.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });

    child.on("exit", (code) => {
      clearTimeout(timer);
      if (code !== 0 && !answer) {
        reject(new Error(stderr.trim() || `agent exit ${code}`));
        return;
      }
      resolve({
        transport: "agent-cli-stream-json",
        ttftAssistantMs: ttftAssistantMs == null ? null : Math.round(ttftAssistantMs),
        ttftThinkingMs: ttftThinkingMs == null ? null : Math.round(ttftThinkingMs),
        ttftVisibleMs: ttftAssistantMs == null ? null : Math.round(ttftAssistantMs),
        totalMs: Math.round(performance.now() - t0),
        answer: answer.trim(),
        exitCode: code,
      });
    });

    const rl = readline.createInterface({ input: child.stdout });
    rl.on("line", (line) => {
      const raw = String(line || "").trim();
      if (!raw) return;
      let obj;
      try {
        obj = JSON.parse(raw);
      } catch {
        return;
      }
      const now = performance.now() - t0;
      if (obj.type === "thinking" && ttftThinkingMs == null) ttftThinkingMs = now;
      const piece = extractAssistantPiece(obj);
      if (piece) {
        if (ttftAssistantMs == null) ttftAssistantMs = now;
        answer += piece;
      }
    });
  });
}

const engine = detectCursorEngine();
if (!engine) {
  console.error("Cursor agent CLI 未找到");
  process.exit(1);
}

const store = await loadStore();
const catalog = await listBooks(store.config.workspaceRoot);
if (!catalog.books?.length) {
  console.error("书库为空");
  process.exit(1);
}

const book = await resolveBook(store.config.workspaceRoot, catalog.books[0].id);
const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
const cacheDir = materialized.cacheDir;
const chapter = "";

const bookContext = await formatBookAcpContext(book, materialized);
const promptText = buildBookAcpPrompt({
  question: messageArg,
  bookContext,
  seedHistory: false,
  currentChapter: chapter || undefined,
  spokenAnswer: false,
});

console.log("=== ACP vs Agent CLI（同目录 · 同 prompt 体）===");
console.log("书:", book.title);
console.log("cwd:", cacheDir);
console.log("模型:", acpModelId());
console.log("问题:", messageArg);
console.log("prompt 字数:", [...promptText].length);
console.log("");

console.log("[1/2] ACP（warm + createBookAskIterator）…");
const acpRow = await runAcp({
  question: messageArg,
  book,
  materialized,
  cacheDir,
  chapter,
  promptText,
});
console.log(
  `  TTFT(可见 delta): ${acpRow.ttftVisibleMs ?? "n/a"} ms | 总: ${acpRow.totalMs} ms | ${[...acpRow.answer].length} 字`,
);
console.log(`  摘要: ${acpRow.answer.slice(0, 120)}${acpRow.answer.length > 120 ? "…" : ""}`);
console.log("");

console.log("[2/2] Agent CLI（-p stream-json，单次冷启动）…");
let cliRow;
try {
  cliRow = await runAgentCli({ cwd: cacheDir, prompt: promptText });
  console.log(
    `  TTFT(assistant): ${cliRow.ttftAssistantMs ?? "n/a"} ms | thinking 首包: ${cliRow.ttftThinkingMs ?? "n/a"} ms | 总: ${cliRow.totalMs} ms | ${[...cliRow.answer].length} 字`,
  );
  console.log(`  摘要: ${cliRow.answer.slice(0, 120)}${cliRow.answer.length > 120 ? "…" : ""}`);
} catch (err) {
  cliRow = { transport: "agent-cli-stream-json", error: String(err.message || err) };
  console.log("  失败:", cliRow.error);
}

console.log("");
console.log("=== 对比 ===");
if (acpRow.ttftVisibleMs != null && cliRow.ttftVisibleMs != null) {
  const delta = acpRow.ttftVisibleMs - cliRow.ttftVisibleMs;
  console.log(
    `可见首字 TTFT: ACP ${acpRow.ttftVisibleMs} ms vs CLI ${cliRow.ttftVisibleMs} ms（ACP - CLI = ${delta} ms，负值表示 CLI 更快）`,
  );
  console.log(`总耗时: ACP ${acpRow.totalMs} ms vs CLI ${cliRow.totalMs ?? "n/a"} ms`);
} else {
  console.log("TTFT 有一侧未测到，请看上方明细。");
}

const out = {
  at: new Date().toISOString(),
  book: book.title,
  cacheDir,
  model: acpModelId(),
  question: messageArg,
  acp: acpRow,
  cli: cliRow,
};
const outDir = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "test-output");
mkdirSync(outDir, { recursive: true });
const outFile = path.join(outDir, "book-acp-vs-cli-bench.json");
writeFileSync(outFile, `${JSON.stringify(out, null, 2)}\n`);
console.log("");
console.log("已写入:", outFile);
