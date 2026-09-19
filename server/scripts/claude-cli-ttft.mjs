/**
 * Claude Code CLI (-p stream-json) TTFT bench (model via WENXIANG_CLAUDE_MODEL).
 * Compare against ACP if the agent adapter hangs.
 */
import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { loadLocalEnv } from "../src/env.js";

loadLocalEnv();

const MODEL = String(process.env.WENXIANG_CLAUDE_MODEL || "MiniMax-M3").trim();
const KEY = String(process.env.OPENROUTER_API_KEY || "").trim();
const BASE = (process.env.OPENROUTER_BASE_URL || "https://openrouter.ai/api").replace(/\/+$/, "");
const QUESTION = process.argv.includes("--message")
  ? process.argv[process.argv.indexOf("--message") + 1]
  : "只回复一个字：好";

if (!KEY) {
  console.error("OPENROUTER_API_KEY missing");
  process.exit(1);
}

const claude = [
  path.join(os.homedir(), ".local", "bin", "claude.exe"),
  path.join(os.homedir(), ".local", "bin", "claude"),
].find((p) => existsSync(p));

if (!claude) {
  console.error("claude CLI not found");
  process.exit(1);
}

const cwd = process.argv.includes("--cwd")
  ? process.argv[process.argv.indexOf("--cwd") + 1]
  : process.cwd();

const isolatedDir = path.join(os.tmpdir(), "wenxiang-claude-openrouter-ttft");
mkdirSync(isolatedDir, { recursive: true });
const settingsFile = path.join(isolatedDir, "settings.json");
writeFileSync(
  settingsFile,
  `${JSON.stringify(
    {
      env: {
        ANTHROPIC_BASE_URL: BASE,
        ANTHROPIC_AUTH_TOKEN: KEY,
        ANTHROPIC_MODEL: MODEL,
        ANTHROPIC_DEFAULT_SONNET_MODEL: MODEL,
        ANTHROPIC_DEFAULT_OPUS_MODEL: MODEL,
        ANTHROPIC_DEFAULT_HAIKU_MODEL: MODEL,
        CLAUDE_MODEL: MODEL,
      },
    },
    null,
    2,
  )}\n`,
);

const args = [
  "-p",
  QUESTION,
  "--output-format",
  "stream-json",
  "--verbose",
  "--include-partial-messages",
  "--model",
  MODEL,
  "--dangerously-skip-permissions",
  "--setting-sources",
  "",
  "--settings",
  settingsFile,
];

console.log({
  bin: claude,
  model: MODEL,
  base: BASE,
  cwd,
  question: QUESTION,
});

const t0 = performance.now();
let ttftMs = null;
let answer = "";
let events = [];
let stderr = "";

const env = {
  ...process.env,
  ANTHROPIC_BASE_URL: BASE,
  ANTHROPIC_AUTH_TOKEN: KEY,
  CLAUDE_MODEL: MODEL,
  ANTHROPIC_MODEL: MODEL,
  ANTHROPIC_DEFAULT_SONNET_MODEL: MODEL,
  ANTHROPIC_DEFAULT_OPUS_MODEL: MODEL,
  ANTHROPIC_DEFAULT_HAIKU_MODEL: MODEL,
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: "1",
  CLAUDE_CONFIG_DIR: isolatedDir,
};
delete env.ANTHROPIC_API_KEY;

const child = spawn(claude, args, {
  cwd,
  stdio: ["ignore", "pipe", "pipe"],
  windowsHide: true,
  env,
});

const timer = setTimeout(() => {
  child.kill("SIGTERM");
}, 90_000);

child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

const rl = readline.createInterface({ input: child.stdout });
rl.on("line", (line) => {
  const raw = String(line || "").trim();
  if (!raw) return;
  let obj;
  try {
    obj = JSON.parse(raw);
  } catch {
    events.push({ type: "non-json", preview: raw.slice(0, 80) });
    return;
  }
  if (events.length < 20) {
    events.push({ type: obj.type, subtype: obj.subtype || undefined });
  }
  if (obj.type !== "assistant" && obj.type !== "stream_event") return;
  let piece = "";
  if (obj.type === "assistant") {
    const parts = obj?.message?.content;
    if (Array.isArray(parts)) {
      piece = parts.filter((p) => p?.type === "text" && p.text).map((p) => p.text).join("");
    }
  } else if (obj.event?.delta?.text) {
    piece = obj.event.delta.text;
  } else if (obj.event?.delta?.type === "text_delta") {
    piece = obj.event.delta.text || "";
  }
  if (!piece) return;
  if (ttftMs == null) ttftMs = performance.now() - t0;
  answer += piece;
});

const code = await new Promise((resolve) => {
  child.on("exit", (c) => resolve(c));
});
clearTimeout(timer);

console.log({
  exit: code,
  ttftMs: ttftMs == null ? null : Math.round(ttftMs),
  totalMs: Math.round(performance.now() - t0),
  chars: answer.trim().length,
  preview: answer.trim().replace(/\s+/g, " ").slice(0, 80),
  events,
  stderrTail: stderr.trim().slice(-600),
});
if (ttftMs == null) process.exitCode = 1;
