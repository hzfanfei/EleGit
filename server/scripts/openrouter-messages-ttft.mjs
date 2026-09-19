import { loadLocalEnv } from "../src/env.js";

loadLocalEnv();

const MODEL = String(process.env.WENXIANG_CLAUDE_MODEL || "MiniMax-M3").trim();
const KEY = String(process.env.OPENROUTER_API_KEY || "").trim();
if (!KEY) {
  console.error("OPENROUTER_API_KEY missing");
  process.exit(1);
}

const t0 = performance.now();
const res = await fetch("https://openrouter.ai/api/v1/messages", {
  method: "POST",
  headers: {
    Authorization: `Bearer ${KEY}`,
    "x-api-key": KEY,
    "anthropic-version": "2023-06-01",
    "Content-Type": "application/json",
    "HTTP-Referer": "https://github.com/hzfanfei/EleGit",
    "X-Title": "EleGit Claude ACP TTFT",
  },
  body: JSON.stringify({
    model: MODEL,
    max_tokens: 32,
    stream: true,
    messages: [{ role: "user", content: "只回复一个字：好" }],
  }),
});

console.log({ status: res.status, contentType: res.headers.get("content-type") });
if (!res.ok) {
  const body = await res.text();
  console.log({ error: body.slice(0, 400), ms: Math.round(performance.now() - t0) });
  process.exit(1);
}

let ttftMs = null;
let answer = "";
const decoder = new TextDecoder();
const reader = res.body.getReader();
let buffer = "";
while (true) {
  const { done, value } = await reader.read();
  if (done) break;
  buffer += decoder.decode(value, { stream: true });
  const lines = buffer.split("\n");
  buffer = lines.pop() || "";
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("data:")) continue;
    const data = trimmed.slice(5).trim();
    if (!data || data === "[DONE]") continue;
    let obj;
    try {
      obj = JSON.parse(data);
    } catch {
      continue;
    }
    const piece =
      obj?.delta?.text ||
      obj?.delta?.text_delta ||
      (obj?.type === "content_block_delta" ? obj?.delta?.text : "") ||
      "";
    if (!piece) continue;
    if (ttftMs == null) ttftMs = performance.now() - t0;
    answer += piece;
  }
}

console.log({
  transport: "openrouter-anthropic-messages",
  ttftMs,
  totalMs: Math.round(performance.now() - t0),
  preview: answer.replace(/\s+/g, " ").slice(0, 80),
});
