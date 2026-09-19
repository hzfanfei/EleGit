/**
 * One-off: Claude Code ACP (zed claude-agent-acp) TTFT bench (MiniMax / optional OpenRouter).
 * Measures visible first-token (首字) time. Does not change the production Cursor default.
 *
 *   node scripts/claude-acp-ttft.mjs
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { acpVisibleTextFromUpdate, buildBookAcpPrompt, selectPermissionOption } from "../src/acp.js";
import { loadLocalEnv } from "../src/env.js";
import { loadStore } from "../src/store.js";
import {
  ensureBookMaterialized,
  formatBookAcpContext,
  listBooks,
  resolveBook,
} from "../src/books.js";

loadLocalEnv();

const USE_USER_SETTINGS =
  process.argv.includes("--minimax") || process.argv.includes("--user-settings");
const MODEL = String(process.env.WENXIANG_CLAUDE_MODEL || "MiniMax-M3").trim();
const OPENROUTER_BASE = (
  process.env.OPENROUTER_BASE_URL || "https://openrouter.ai/api"
).replace(/\/+$/, "");
const OPENROUTER_KEY = String(process.env.OPENROUTER_API_KEY || "").trim();
const SHORT_ONLY = process.argv.includes("--short");
const ONCE = process.argv.includes("--once");
const NO_THINKING = process.argv.includes("--no-thinking") || ONCE;
const ASK_MODE = process.argv.includes("--ask") || ONCE;
const QUESTION =
  process.argv.includes("--message") && process.argv[process.argv.indexOf("--message") + 1]
    ? process.argv[process.argv.indexOf("--message") + 1]
    : ONCE
      ? "用三句话总结这本书想告诉读者什么。"
      : "用朋友聊天的口气，一句话说清这本书讲啥。";
const USE_GATEWAY = !USE_USER_SETTINGS && !process.argv.includes("--no-gateway");

if (!USE_USER_SETTINGS && !OPENROUTER_KEY) {
  console.error("OPENROUTER_API_KEY missing in .env");
  process.exit(1);
}

function readTextUnderCwd(cwd, rawPath) {
  const abs = path.resolve(cwd, String(rawPath || ""));
  const root = path.resolve(cwd);
  if (abs !== root && !abs.startsWith(`${root}${path.sep}`)) {
    throw new Error("path outside book cwd");
  }
  return { content: readFileSync(abs, "utf8") };
}

function findClaudeAcp() {
  const npmRoot = path.join(process.env.APPDATA || "", "npm", "node_modules");
  const script =
    [path.join(npmRoot, "@agentclientprotocol", "claude-agent-acp", "dist", "index.js"),
      path.join(npmRoot, "@zed-industries", "claude-agent-acp", "dist", "index.js"),
    ].find((p) => existsSync(p)) || "";
  if (script) {
    return { id: "claude-agent-acp", path: process.execPath, args: [script], script };
  }
  return null;
}

function findClaudeCli() {
  const home = os.homedir();
  for (const candidate of [
    path.join(home, ".local", "bin", "claude.exe"),
    path.join(home, ".local", "bin", "claude"),
  ]) {
    if (existsSync(candidate)) return candidate;
  }
  return "";
}

class AcpClient {
  constructor({ command, cwd, env }) {
    this.command = command;
    this.cwd = cwd;
    this.env = env;
    this.child = null;
    this.nextId = 1;
    this.pending = new Map();
    this.onDelta = null;
    this.onThought = null;
    this.onEvent = null;
    this.stderr = "";
  }

  startProcess() {
    this.child = spawn(this.command.path, this.command.args, {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      env: this.env,
    });
    this.child.on("error", (err) => this._failAll(err));
    this.child.on("exit", (code, signal) => {
      this._failAll(new Error(`claude-agent-acp exited ${code ?? signal}`));
    });
    const rl = readline.createInterface({ input: this.child.stdout });
    rl.on("line", (line) => this._onLine(line));
    this.child.stderr?.on("data", (chunk) => {
      this.stderr += chunk.toString();
    });
  }

  async initialize() {
    return this.request("initialize", {
      protocolVersion: 1,
      clientCapabilities: {
        fs: { readTextFile: true, writeTextFile: false },
        terminal: false,
        ...(USE_GATEWAY ? { auth: { _meta: { gateway: true } } } : {}),
      },
      clientInfo: { name: "wenxiang-claude-ttft", version: "0.1.0" },
    });
  }

  async authenticateGateway() {
    return this.request("authenticate", {
      methodId: "gateway",
      _meta: {
        gateway: {
          baseUrl: OPENROUTER_BASE,
          headers: {
            Authorization: `Bearer ${OPENROUTER_KEY}`,
            "x-api-key": OPENROUTER_KEY,
            "HTTP-Referer": "https://github.com/hzfanfei/EleGit",
            "X-Title": "EleGit Claude ACP TTFT",
          },
        },
      },
    });
  }

  async newSession() {
    return this.request(
      "session/new",
      {
        cwd: this.cwd,
        mcpServers: [],
        _meta: {
          claudeCode: {
            options: {
              model: MODEL,
              permissionMode: ASK_MODE ? "plan" : "acceptEdits",
              allowDangerouslySkipPermissions: true,
              ...(NO_THINKING ? {} : { thinking: { type: "adaptive" } }),
              ...(USE_USER_SETTINGS
                ? { settingSources: ["user"] }
                : {
                    settingSources: [],
                    env: {
                      ANTHROPIC_BASE_URL: OPENROUTER_BASE,
                      ANTHROPIC_AUTH_TOKEN: OPENROUTER_KEY,
                      ANTHROPIC_MODEL: MODEL,
                      CLAUDE_MODEL: MODEL,
                    },
                  }),
            },
          },
        },
      },
      60_000,
    );
  }

  async prompt(text, { onDelta, timeoutMs = 180_000 } = {}) {
    this.onDelta = onDelta;
    try {
      return await this.request(
        "session/prompt",
        {
          sessionId: this.sessionId,
          prompt: [{ type: "text", text }],
        },
        timeoutMs,
      );
    } finally {
      this.onDelta = null;
    }
  }

  cancelPrompt() {
    if (!this.child?.stdin || !this.sessionId) return;
    try {
      this.child.stdin.write(
        `${JSON.stringify({
          jsonrpc: "2.0",
          method: "session/cancel",
          params: { sessionId: this.sessionId },
        })}\n`,
      );
    } catch {
      // Best-effort after stream metrics are collected.
    }
  }

  request(method, params, timeoutMs = 30_000) {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      if (!this.child?.stdin) {
        reject(new Error("ACP process is not running"));
        return;
      }
      const timer = setTimeout(() => {
        this.pending.delete(id);
        const tail = this.stderr.trim().slice(-800);
        reject(new Error(`ACP ${method} timed out${tail ? `\nstderr: ${tail}` : ""}`));
      }, timeoutMs);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (err) => {
          clearTimeout(timer);
          reject(err);
        },
      });
      this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
    });
  }

  respond(id, result) {
    if (!this.child?.stdin) return;
    this.child.stdin.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
  }

  respondError(id, message) {
    if (!this.child?.stdin) return;
    this.child.stdin.write(
      `${JSON.stringify({ jsonrpc: "2.0", id, error: { code: -32000, message } })}\n`,
    );
  }

  _onLine(line) {
    const raw = String(line || "").trim();
    if (!raw) return;
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
      this.onEvent?.({ kind: "non-json", preview: raw.slice(0, 120) });
      return;
    }
    if (msg.id != null && (msg.result !== undefined || msg.error)) {
      const waiter = this.pending.get(msg.id);
      if (!waiter) return;
      this.pending.delete(msg.id);
      if (msg.error) {
        waiter.reject(new Error(msg.error.message || JSON.stringify(msg.error)));
      } else {
        waiter.resolve(msg.result);
      }
      return;
    }
    if (msg.method === "session/update") {
      const update = msg.params?.update || {};
      const kind = String(update.sessionUpdate || "update");
      const visible = acpVisibleTextFromUpdate(update);
      const thought =
        kind === "agent_thought_chunk" || kind === "agent_thought"
          ? typeof update.content === "string"
            ? update.content
            : update.content?.text || ""
          : "";
      this.onEvent?.({
        kind,
        visible: Boolean(visible),
        thought: Boolean(thought),
        tool: update.title || update.toolCall?.title || update.kind || undefined,
        path: update.locations?.[0]?.path || update.path || undefined,
      });
      if (thought) this.onThought?.(thought);
      if (visible) this.onDelta?.(visible);
      return;
    }
    if (msg.method === "session/request_permission") {
      this.onEvent?.({
        kind: "request_permission",
        tool: msg.params?.toolCall?.title || msg.params?.toolCall?.kind,
      });
      this.respond(msg.id, {
        outcome: { outcome: "selected", optionId: selectPermissionOption(msg.params) },
      });
      return;
    }
    if (msg.method === "fs/read_text_file") {
      this.onEvent?.({ kind: "fs/read_text_file", path: msg.params?.path });
      try {
        this.respond(msg.id, readTextUnderCwd(this.cwd, msg.params?.path));
      } catch (err) {
        this.respondError(msg.id, err.message);
      }
      return;
    }
    if (msg.method === "fs/write_text_file") {
      this.respondError(msg.id, "write disabled");
      return;
    }
    if (msg.method && msg.id != null) {
      this.onEvent?.({ kind: `request:${msg.method}` });
      this.respondError(msg.id, `unsupported ${msg.method}`);
    }
  }

  _failAll(err) {
    for (const waiter of this.pending.values()) waiter.reject(err);
    this.pending.clear();
  }

  close() {
    this._failAll(new Error("ACP channel closed"));
    if (this.child && !this.child.killed) this.child.kill("SIGTERM");
    this.child = null;
  }
}

async function openRouterChatTtft(prompt) {
  const t0 = performance.now();
  let ttftMs = null;
  let answer = "";
  const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${OPENROUTER_KEY}`,
      "Content-Type": "application/json",
      "HTTP-Referer": "https://github.com/hzfanfei/EleGit",
      "X-Title": "EleGit Claude ACP TTFT",
    },
    body: JSON.stringify({
      model: MODEL,
      stream: true,
      messages: [{ role: "user", content: prompt }],
    }),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`openrouter ${res.status}: ${body.slice(0, 240)}`);
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
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
      const piece = obj?.choices?.[0]?.delta?.content || "";
      if (!piece) continue;
      if (ttftMs == null) ttftMs = performance.now() - t0;
      answer += piece;
    }
  }
  return {
    transport: "openrouter-chat-completions",
    ttftMs: ttftMs == null ? null : Math.round(ttftMs),
    totalMs: Math.round(performance.now() - t0),
    chars: answer.trim().length,
    preview: answer.trim().replace(/\s+/g, " ").slice(0, 80),
  };
}

const STREAM_IDLE_MS = Number(process.env.WENXIANG_ACP_STREAM_IDLE_MS || 2500);
const STREAM_MAX_MS = Number(process.env.WENXIANG_ACP_STREAM_MAX_MS || 120_000);

function waitForVisibleRoundEnd(getState, t0) {
  const maxMs = ONCE ? STREAM_MAX_MS : 180_000;
  return new Promise((resolve) => {
    const started = performance.now();
    const timer = setInterval(() => {
      const { ttftMs, lastDeltaAt, usageMs } = getState();
      if (usageMs != null) {
        clearInterval(timer);
        resolve({ completeMs: Math.round(usageMs), reason: "usage_update" });
        return;
      }
      if (ttftMs != null && lastDeltaAt && performance.now() - lastDeltaAt >= STREAM_IDLE_MS) {
        clearInterval(timer);
        resolve({ completeMs: Math.round(performance.now() - t0), reason: "idle_after_last_delta" });
        return;
      }
      if (performance.now() - started >= maxMs) {
        clearInterval(timer);
        const completeMs =
          lastDeltaAt != null
            ? Math.round(lastDeltaAt - t0)
            : ttftMs != null
              ? Math.round(ttftMs)
              : null;
        resolve({ completeMs, reason: "max_wait" });
      }
    }, 100);
  });
}

async function runTurn(client, prompt, label) {
  let ttftMs = null;
  let thoughtMs = null;
  let answer = "";
  let lastDeltaAt = null;
  let usageMs = null;
  const events = [];
  const t0 = performance.now();
  client.onEvent = (ev) => {
    if (events.length < 32) events.push(ev);
    if (ev.kind === "usage_update" && ttftMs != null && usageMs == null) {
      usageMs = performance.now() - t0;
    }
  };
  client.onThought = () => {
    if (thoughtMs == null) thoughtMs = performance.now() - t0;
  };

  const onDelta = (text) => {
    if (ttftMs == null) ttftMs = performance.now() - t0;
    answer += text;
    lastDeltaAt = performance.now();
  };

  try {
    if (ONCE) {
      const promptTask = client
        .prompt(prompt, {
          timeoutMs: STREAM_MAX_MS + 60_000,
          onDelta,
        })
        .catch(() => {});

      const { completeMs, reason } = await waitForVisibleRoundEnd(
        () => ({ ttftMs, lastDeltaAt, usageMs }),
        t0,
      );
      client.cancelPrompt();
      await Promise.race([promptTask, new Promise((r) => setTimeout(r, 800))]);

      const thoughtEvents = events.filter((e) => e.kind === "agent_thought_chunk" && e.thought).length;
      return {
        label,
        thoughtMs: thoughtMs == null ? null : Math.round(thoughtMs),
        thoughtChunks: thoughtEvents,
        ttftMs: ttftMs == null ? null : Math.round(ttftMs),
        completeMs,
        completeReason: reason,
        totalMs: completeMs,
        chars: answer.trim().length,
        preview: answer.trim().replace(/\s+/g, " ").slice(0, 80),
        answer: answer.trim(),
        events,
      };
    }

    await client.prompt(prompt, {
      timeoutMs: 180_000,
      onDelta,
    });
  } catch (err) {
    err.events = events;
    err.stderr = client.stderr.trim().slice(-800);
    err.partial = {
      thoughtMs: thoughtMs == null ? null : Math.round(thoughtMs),
      ttftMs: ttftMs == null ? null : Math.round(ttftMs),
      chars: answer.trim().length,
    };
    throw err;
  } finally {
    client.onEvent = null;
    client.onThought = null;
  }
  const thoughtEvents = events.filter((e) => e.kind === "agent_thought_chunk" && e.thought).length;
  return {
    label,
    thoughtMs: thoughtMs == null ? null : Math.round(thoughtMs),
    thoughtChunks: thoughtEvents,
    ttftMs: ttftMs == null ? null : Math.round(ttftMs),
    completeMs: Math.round(performance.now() - t0),
    completeReason: "session/prompt",
    totalMs: Math.round(performance.now() - t0),
    chars: answer.trim().length,
    preview: answer.trim().replace(/\s+/g, " ").slice(0, 80),
    answer: answer.trim(),
    events,
  };
}

const adapter = findClaudeAcp();
if (!adapter) {
  console.error(
    "claude-agent-acp not found (npm global @agentclientprotocol/claude-agent-acp)",
  );
  process.exit(1);
}

const claudeCli = findClaudeCli();
const store = await loadStore();
const { books } = await listBooks(store.config.workspaceRoot);
if (!books.length) {
  console.error("No EPUB in workspace books dir");
  process.exit(1);
}
const book = await resolveBook(store.config.workspaceRoot, books[0].id);
const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
const bookContext = await formatBookAcpContext(book, materialized);
const promptText = buildBookAcpPrompt({
  book,
  bookContext,
  question: QUESTION,
  history: [],
});

const env = { ...process.env };
if (!USE_USER_SETTINGS) {
  const isolatedDir = path.join(os.tmpdir(), "wenxiang-claude-openrouter-ttft");
  mkdirSync(isolatedDir, { recursive: true });
  writeFileSync(
    path.join(isolatedDir, "settings.json"),
    `${JSON.stringify(
      {
        env: {
          ANTHROPIC_BASE_URL: OPENROUTER_BASE,
          ANTHROPIC_AUTH_TOKEN: OPENROUTER_KEY,
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
  delete env.ANTHROPIC_API_KEY;
  env.ANTHROPIC_BASE_URL = OPENROUTER_BASE;
  env.ANTHROPIC_AUTH_TOKEN = OPENROUTER_KEY;
  env.CLAUDE_MODEL = MODEL;
  env.ANTHROPIC_MODEL = MODEL;
  env.ANTHROPIC_DEFAULT_SONNET_MODEL = MODEL;
  env.ANTHROPIC_DEFAULT_OPUS_MODEL = MODEL;
  env.ANTHROPIC_DEFAULT_HAIKU_MODEL = MODEL;
  env.CLAUDE_CONFIG_DIR = isolatedDir;
}
if (claudeCli) env.CLAUDE_CODE_EXECUTABLE = claudeCli;

const client = new AcpClient({
  command: adapter,
  cwd: materialized.cacheDir,
  env,
});

if (!ONCE) {
  console.log(
    JSON.stringify(
      {
        adapter: adapter.id,
        model: MODEL,
        provider: USE_USER_SETTINGS ? "minimax-user-settings" : "openrouter",
        gateway: USE_USER_SETTINGS ? null : OPENROUTER_BASE,
        useGateway: USE_GATEWAY,
        claudeCli: Boolean(claudeCli),
        book: { id: book.id, title: book.title },
        cwd: materialized.cacheDir,
        tools: "claude_code",
        noThinking: NO_THINKING,
        question: QUESTION,
        promptChars: promptText.length,
      },
      null,
      2,
    ),
  );
}

if (!USE_USER_SETTINGS && !ONCE) {
  console.log("openrouter raw", await openRouterChatTtft("只回复一个字：好"));
}

const bootT0 = performance.now();
client.startProcess();
const init = await client.initialize();
const authMethods = (init?.authMethods || []).map((m) => m.id);
if (!ONCE) {
  console.log("initialize", {
    protocolVersion: init?.protocolVersion,
    agent: init?.agentInfo?.name || init?.agentInfo?.title,
    authMethods,
    bootMs: Math.round(performance.now() - bootT0),
  });
}

if (USE_GATEWAY && authMethods.includes("gateway")) {
  await client.authenticateGateway();
  console.log("authenticated gateway");
} else {
  console.log(
    USE_USER_SETTINGS
      ? "using ~/.claude/settings.json (MiniMax)"
      : "using process env ANTHROPIC_* for OpenRouter (no gateway wipe)",
  );
}

let created;
try {
  created = await client.newSession();
} catch (err) {
  console.error("session/new failed:", err.message);
  const stderr = client.stderr.trim().slice(-800);
  if (stderr) console.error("stderr:", stderr);
  client.close();
  process.exit(1);
}
client.sessionId = created?.sessionId || created?.session_id || "";
if (!client.sessionId) throw new Error("session/new did not return sessionId");
const models = created?.models?.availableModels?.map((m) => m.modelId) || [];
if (!ONCE) {
  console.log("session/new", {
    sessionId: `${client.sessionId.slice(0, 8)}…`,
    currentModel: created?.models?.currentModelId || null,
    availableModels: models.slice(0, 8),
    modes: (created?.modes?.availableModes || []).map((m) => m.id),
    bootMs: Math.round(performance.now() - bootT0),
  });
}
const modes = created?.modes?.availableModes || [];
if (ASK_MODE) {
  for (const modeId of ["ask", "plan", "dontAsk"]) {
    if (!modes.some((m) => (m.id || m.modeId) === modeId)) continue;
    try {
      await client.request("session/set_mode", {
        sessionId: client.sessionId,
        modeId,
      });
      console.log("session/set_mode", modeId);
      break;
    } catch (err) {
      console.log(`set_mode ${modeId} skipped:`, err.message);
    }
  }
}

if (USE_USER_SETTINGS || process.argv.includes("--set-model")) {
  try {
    await client.request("session/set_config_option", {
      sessionId: client.sessionId,
      configId: "model",
      value: MODEL,
    });
    console.log("set_config_option model ok");
  } catch (err) {
    console.log("model pin skipped:", err.message);
  }
} else {
  console.log("skip set_config_option; relying on CLAUDE_MODEL / session options");
}

const runT0 = performance.now();
try {
  const shortPrompt = "只回复一个字：好";
  const firstPrompt = SHORT_ONLY ? shortPrompt : promptText;
  const cold = await runTurn(client, firstPrompt, SHORT_ONLY ? "short" : "once");
  if (ONCE) {
    const { events: _events, answer: fullAnswer, ...metrics } = cold;
    console.log(
      JSON.stringify(
        {
          book: { id: book.id, title: book.title },
          cwd: materialized.cacheDir,
          model: MODEL,
          mode: ASK_MODE ? "ask/plan" : "default",
          question: QUESTION,
          ttftMs: metrics.ttftMs,
          completeMs: metrics.completeMs,
          completeReason: metrics.completeReason,
          bootMs: Math.round(performance.now() - bootT0),
          endToEndMs: Math.round(performance.now() - runT0),
          chars: metrics.chars,
          answer: fullAnswer,
        },
        null,
        2,
      ),
    );
  } else {
    console.log("turn1", cold);
    if (!SHORT_ONLY) {
      const warm = await runTurn(client, "再短一点，十个字以内。", "warm");
      console.log("turn2", warm);
    }
  }
} catch (err) {
  console.error("prompt failed:", err.message);
  if (err.partial) console.error("partial:", err.partial);
  if (err.events?.length) console.error("events:", err.events);
  const stderr = err.stderr || client.stderr.trim().slice(-800);
  if (stderr) console.error("stderr:", stderr);
  process.exitCode = 1;
} finally {
  const leftover = client.stderr.trim().slice(-800);
  if (leftover) console.log("stderr leftover:", leftover);
  client.close();
}
