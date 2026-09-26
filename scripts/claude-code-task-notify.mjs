// Claude Code Stop hook: when a response contains the marker
// ===TASK_COMPLETED===, push a notification to the local Wenxiang server
// so the user's phone buzzes. Runs after every assistant turn; bails out
// silently if the marker is absent.
//
// Wired up in `.claude/settings.json` as a project-scoped hook.
//
// Reads `.env` from the project root for WENXIANG_PUBLIC_URL and
// WENXIANG_API_KEY. Failures only console.warn; never break Claude Code.

import { readFileSync, existsSync } from "node:fs";
import path from "node:path";

const MARKER_RE = /^===TASK_COMPLETED===\s*$/m;

function readEnv(cwd) {
  const envPath = path.join(cwd, ".env");
  if (!existsSync(envPath)) return {};
  const text = readFileSync(envPath, "utf8");
  const out = {};
  for (const line of text.split(/\r?\n/)) {
    const m = line.match(/^([A-Z0-9_]+)=(.*)$/);
    if (!m) continue;
    out[m[1]] = m[2].trim().replace(/^['"]|['"]$/g, "");
  }
  return out;
}

function readStdin() {
  return new Promise((resolve) => {
    let buf = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      buf += chunk;
    });
    process.stdin.on("end", () => resolve(buf));
  });
}

function lastAssistantText(transcriptPath) {
  if (!existsSync(transcriptPath)) return "";
  const lines = readFileSync(transcriptPath, "utf8").split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i].trim();
    if (!line) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (!entry || entry.type !== "assistant") continue;
    const msg = entry.message || {};
    const blocks = Array.isArray(msg.content) ? msg.content : [];
    const texts = [];
    for (const block of blocks) {
      if (block && block.type === "text" && typeof block.text === "string") {
        texts.push(block.text);
      }
    }
    if (texts.length) return texts.join("\n");
  }
  return "";
}

function summariseAfterMarker(fullText) {
  const m = fullText.match(MARKER_RE);
  if (!m) return null;
  const idx = m.index ?? 0;
  const tail = fullText.slice(idx + m[0].length).replace(/^\s*\n/, "").trim();
  if (!tail) return { title: "Claude Code 后台任务完成", body: "已就绪" };
  // Take the first non-empty line as the title; everything else as body.
  const lines = tail.split(/\r?\n/);
  const first = lines.shift() || "";
  const rest = lines.join("\n").trim();
  const title = (first || "Claude Code 后台任务完成").slice(0, 80);
  const body = (rest || first || "已就绪").slice(0, 240);
  return { title, body };
}

async function postNotification({ url, key, payload }) {
  const res = await fetch(`${url.replace(/\/$/, "")}/v1/inbox`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Wenxiang-Key": key,
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    throw new Error(`HTTP ${res.status}: ${text.slice(0, 200)}`);
  }
}

async function main() {
  const raw = await readStdin();
  let input = {};
  try {
    input = JSON.parse(raw);
  } catch {
    process.exit(0);
  }
  const transcriptPath = input.transcript_path;
  const cwd = input.cwd || process.cwd();
  if (!transcriptPath) process.exit(0);

  const fullText = lastAssistantText(transcriptPath);
  if (!fullText || !MARKER_RE.test(fullText)) process.exit(0);

  const summary = summariseAfterMarker(fullText);
  if (!summary) process.exit(0);

  const env = readEnv(cwd);
  const url = env.WENXIANG_PUBLIC_URL || process.env.WENXIANG_PUBLIC_URL || "";
  const key = env.WENXIANG_API_KEY || process.env.WENXIANG_API_KEY || "";
  if (!url || !key) {
    console.warn("[claude-code-task-notify] .env 缺 WENXIANG_PUBLIC_URL 或 WENXIANG_API_KEY，跳过通知");
    process.exit(0);
  }

  try {
    await postNotification({
      url,
      key,
      payload: {
        kind: "claude-code-task",
        title: summary.title,
        body: summary.body,
      },
    });
  } catch (err) {
    console.warn(`[claude-code-task-notify] 推送失败: ${err.message || err}`);
  }
  process.exit(0);
}

main();
