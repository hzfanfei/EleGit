/**
 * Measure chat time-to-first-token (SSE events) against the local companion.
 * Usage: node scripts/bench-ttft.mjs [--warm] [--owner X] [--repo Y]
 */
import { readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const home = process.env.WENXIANG_HOME || path.join(os.homedir(), ".wenxiang");
const cfg = JSON.parse(await readFile(path.join(home, "config.json"), "utf8"));
const port = Number(process.env.WENXIANG_PORT || 8787);
const base = `http://127.0.0.1:${port}`;
const headers = {
  "X-Wenxiang-Key": cfg.apiKey,
  "Content-Type": "application/json",
  Accept: "text/event-stream",
};

const args = process.argv.slice(2);
const doWarm = args.includes("--warm");
const ownerIdx = args.indexOf("--owner");
const repoIdx = args.indexOf("--repo");
const owner = ownerIdx >= 0 ? args[ownerIdx + 1] : "hzfanfei";
const repo = repoIdx >= 0 ? args[repoIdx + 1] : "fwechat";

async function health() {
  const res = await fetch(`${base}/health`);
  return res.ok;
}

async function createSession() {
  const res = await fetch(`${base}/v1/repos/${owner}/${repo}/sessions`, {
    method: "POST",
    headers: { "X-Wenxiang-Key": cfg.apiKey },
  });
  if (!res.ok) throw new Error(`create session ${res.status}`);
  return res.json();
}

async function warmSession() {
  const t0 = performance.now();
  const res = await fetch(`${base}/v1/repos/${owner}/${repo}/sessions/warm`, {
    method: "POST",
    headers: {
      "X-Wenxiang-Key": cfg.apiKey,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({}),
  });
  const ms = performance.now() - t0;
  const body = res.ok ? await res.json() : {};
  return { ms, body };
}

async function chatOnce(sessionId, message) {
  const t0 = performance.now();
  const marks = { t0 };
  const res = await fetch(`${base}/v1/chat`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      owner,
      repo,
      message,
      sessionId,
      history: [{ role: "user", content: message }],
    }),
  });
  marks.httpHeaders = performance.now() - t0;
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`chat ${res.status}: ${text.slice(0, 200)}`);
  }
  const reader = res.body.getReader();
  const dec = new TextDecoder();
  let buf = "";
  let firstDelta = null;
  let firstStart = null;
  let firstMeta = null;
  let deltaCount = 0;
  let answer = "";

  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += dec.decode(value, { stream: true });
    const parts = buf.split("\n\n");
    buf = parts.pop() || "";
    for (const block of parts) {
      const dataLine = block.split("\n").find((l) => l.startsWith("data:"));
      if (!dataLine) continue;
      const json = JSON.parse(dataLine.slice(5).trim());
      const now = performance.now() - t0;
      if (json.type === "meta" && firstMeta == null) firstMeta = now;
      if (json.type === "start" && firstStart == null) firstStart = now;
      if (json.type === "delta" && json.text) {
        deltaCount += 1;
        answer += json.text;
        if (firstDelta == null) firstDelta = now;
      }
      if (json.type === "done") marks.done = now;
    }
    if (firstDelta != null && deltaCount > 3) {
      reader.cancel().catch(() => {});
      break;
    }
  }

  return {
    firstMeta,
    firstStart,
    firstDelta,
    httpHeaders: marks.httpHeaders,
    done: marks.done,
    deltaCount,
    answerLen: answer.length,
  };
}

if (!(await health())) {
  console.error(`Server not up at ${base}. Run: cd server && npm start`);
  process.exit(1);
}

console.log(`Repo: ${owner}/${repo}  warm=${doWarm}`);

const session = await createSession();
console.log(`Session: ${session.id}`);

if (doWarm) {
  const w = await warmSession();
  console.log(`Warm API (repo channel): ${w.ms.toFixed(0)}ms`, w.body);
}

const runs = [];
for (let i = 0; i < 3; i++) {
  const msg = i === 0 ? "用一句话说这个项目是干什么的" : `第${i + 1}次：仓库默认分支叫什么？`;
  const r = await chatOnce(session.id, msg);
  runs.push(r);
  console.log(
    `Run ${i + 1}: meta=${fmt(r.firstMeta)} start=${fmt(r.firstStart)} ` +
      `firstDelta=${fmt(r.firstDelta)} headers=${fmt(r.httpHeaders)} chars=${r.answerLen}`,
  );
  await new Promise((r) => setTimeout(r, 500));
}

const cold = runs[0];
const warmFollow = runs[1];
console.log("\n--- summary (ms from POST) ---");
console.log(`First message — first visible token (delta): ${fmt(cold.firstDelta)}`);
console.log(`First message — SSE start event:            ${fmt(cold.firstStart)}`);
console.log(`Second message (ACP hot) — first delta:     ${fmt(warmFollow.firstDelta)}`);
if (doWarm) {
  console.log("(ACP was pre-warmed via /sessions/warm before run 1)");
}

function fmt(n) {
  return n == null ? "—" : `${n.toFixed(0)}ms`;
}
