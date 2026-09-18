import { loadLocalEnv } from "../src/env.js";

loadLocalEnv();

const base = `http://127.0.0.1:${process.env.WENXIANG_PORT || 8787}`;
const wxKey = String(process.env.WENXIANG_API_KEY || "").trim();

if (!wxKey) {
  console.error("WENXIANG_API_KEY missing in .env");
  process.exit(1);
}

const headers = {
  "Content-Type": "application/json",
  "X-Wenxiang-Key": wxKey,
  Accept: "text/event-stream",
};

async function json(path, init = {}) {
  const res = await fetch(`${base}${path}`, {
    ...init,
    headers: { ...headers, ...(init.headers || {}), Accept: "application/json" },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(`${path} ${res.status}: ${body.error || JSON.stringify(body)}`);
  return body;
}

const status = await json("/v1/status");
console.log("books:", status.books);
if (!status.books?.ready) {
  console.error("问书 ACP 未就绪 — 安装 Cursor agent CLI 并 login，然后重启 companion。");
  process.exit(1);
}

const { books } = await json("/v1/books");
if (!books?.length) {
  console.error("No EPUB in workspace books dir");
  process.exit(1);
}
const book = books[0];
console.log("book:", book.id, book.title);

const question = "用一句话说明这本书主要讲什么？";
const t0 = performance.now();
let ttftMs = null;
let firstDelta = "";
let engine = "";
let model = "";

const res = await fetch(`${base}/v1/books/chat`, {
  method: "POST",
  headers,
  body: JSON.stringify({
    bookId: book.id,
    message: question,
    history: [],
  }),
});

if (!res.ok) {
  const err = await res.text();
  console.error("chat failed", res.status, err.slice(0, 400));
  process.exit(1);
}

const reader = res.body.getReader();
const decoder = new TextDecoder();
let buffer = "";

while (true) {
  const { done, value } = await reader.read();
  if (done) break;
  buffer += decoder.decode(value, { stream: true });
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
    if (event.type === "start") {
      engine = event.engine || engine;
      model = event.model || model;
    }
    if (event.type === "delta" && event.text) {
      if (ttftMs == null) {
        ttftMs = performance.now() - t0;
        firstDelta = event.text;
      }
    }
    if (event.type === "done") {
      engine = event.engine || engine;
      model = event.model || model;
    }
    if (event.type === "error") {
      console.error("stream error:", event.error);
      process.exit(1);
    }
  }
}

const totalMs = performance.now() - t0;
console.log("");
console.log("question:", question);
console.log("engine:", engine, "model:", model || status.books.model);
console.log("TTFT (first delta):", ttftMs == null ? "n/a" : `${Math.round(ttftMs)} ms`);
console.log("first chars:", JSON.stringify((firstDelta || "").slice(0, 80)));
console.log("stream total:", `${Math.round(totalMs)} ms`);

if (ttftMs == null) process.exit(1);
