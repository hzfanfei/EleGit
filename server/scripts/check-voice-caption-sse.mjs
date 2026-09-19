/** Quick check that voice-turn emits caption events. */
import { loadLocalEnv } from "../src/env.js";

loadLocalEnv();

const base = `http://127.0.0.1:${process.env.WENXIANG_PORT || 8787}`;
const key = String(process.env.WENXIANG_API_KEY || "").trim();
if (!key) {
  console.error("WENXIANG_API_KEY missing");
  process.exit(1);
}

const books = await fetch(`${base}/v1/books`, {
  headers: { "X-Wenxiang-Key": key },
}).then((r) => r.json());
const bookId = books.books?.[0]?.id;
if (!bookId) {
  console.log("no books");
  process.exit(0);
}

const res = await fetch(`${base}/v1/books/voice-turn`, {
  method: "POST",
  headers: {
    "X-Wenxiang-Key": key,
    "Content-Type": "application/json",
    Accept: "text/event-stream",
  },
  body: JSON.stringify({ bookId, message: "用一句话介绍这本书", history: [] }),
});
const body = await res.text();
const captions = (body.match(/"type":"caption"/g) || []).length;
console.log(`HTTP ${res.status}, caption events: ${captions}`);
process.exit(captions > 0 ? 0 : 1);
