import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import readline from "node:readline";
import { whichSync } from "./which.js";

const ACP_CANDIDATES = [
  { bin: "agent", args: ["acp"] },
  { bin: "cursor-agent", args: ["acp"] },
  { bin: "cursor", args: ["agent", "acp"] },
];

const WRITE_TOOL = /edit|write|delete|move|apply_patch|overwrite|commit/i;

export function resolveAgentCommand() {
  for (const candidate of ACP_CANDIDATES) {
    const resolved = whichSync(candidate.bin);
    if (resolved) {
      return {
        id: "acp",
        bin: candidate.bin,
        path: resolved,
        args: [...authArgs(), ...candidate.args],
        mode: "ask",
        transport: "stdio",
      };
    }
  }
  return null;
}

function authArgs() {
  const args = [];
  if (process.env.CURSOR_API_KEY) {
    args.push("--api-key", process.env.CURSOR_API_KEY);
  } else if (process.env.CURSOR_AUTH_TOKEN) {
    args.push("--auth-token", process.env.CURSOR_AUTH_TOKEN);
  }
  return args;
}

export function detectCursorEngine() {
  return resolveAgentCommand();
}

export function selectPermissionOption(params) {
  const options = Array.isArray(params?.options) ? params.options : [];
  const hint = `${params?.toolCall?.kind || ""} ${params?.toolCall?.title || ""}`;
  const reject = WRITE_TOOL.test(hint);
  const wanted = reject ? "reject-once" : "allow-once";
  const match = options.find((opt) => opt.optionId === wanted);
  if (match) return match.optionId;
  if (!reject) {
    const allow = options.find((opt) => String(opt.optionId || "").startsWith("allow"));
    if (allow) return allow.optionId;
  }
  const deny = options.find((opt) => /reject|deny/i.test(String(opt.optionId || "")));
  if (reject && deny) return deny.optionId;
  return options[0]?.optionId || wanted;
}

export function buildAcpPrompt({ question, history, githubContext, seedHistory }) {
  const lines = [
    "You are 问象, a local repo progress assistant running on the user's computer.",
    "You are in ask mode: read the checkout and answer. Do not edit files, commit, or change the working tree.",
    "Answer in Simplified Chinese unless the user writes in another language.",
    "Do not invent commits, PRs, files, or dates. Prefer the local checkout when it disagrees with stale memory.",
  ];
  if (githubContext) {
    lines.push("", "=== GitHub facts (not always in the working tree) ===", githubContext);
  }
  if (seedHistory) {
    const historyText = (history || [])
      .filter((m) => m?.content && (m.role === "user" || m.role === "assistant"))
      .slice(-16)
      .map((m) => `${m.role === "user" ? "User" : "Assistant"}: ${m.content}`)
      .join("\n");
    if (historyText) {
      lines.push(
        "",
        "=== Prior conversation (restore after reconnect; do not re-answer these) ===",
        historyText,
      );
    }
  }
  lines.push("", "=== Question ===", question);
  return lines.join("\n");
}

export class AcpChannel {
  constructor({ command, cwd, spawnImpl = spawn, idleMs = 15 * 60 * 1000 } = {}) {
    this.command = command;
    this.cwd = cwd;
    this.spawnImpl = spawnImpl;
    this.idleMs = idleMs;
    this.child = null;
    this.sessionId = "";
    this.nextId = 1;
    this.pending = new Map();
    this.alive = false;
    this.idleTimer = null;
    this.onDelta = null;
  }

  async start() {
    if (this.alive) return this.sessionId;
    const file = this.command.path;
    const args = this.command.args;
    const useShell = process.platform === "win32" && /\.(cmd|bat)$/i.test(file);
    this.child = this.spawnImpl(file, args, {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      shell: useShell,
      env: { ...process.env },
    });
    this.child.on("error", (err) => this._failAll(err));
    this.child.on("exit", () => this._dead());
    const rl = readline.createInterface({ input: this.child.stdout });
    rl.on("line", (line) => this._onLine(line));
    this.stderr = "";
    this.child.stderr?.on("data", (chunk) => {
      this.stderr += chunk.toString();
    });

    try {
      const init = await this.request("initialize", {
        protocolVersion: 1,
        clientCapabilities: {
          fs: { readTextFile: false, writeTextFile: false },
          terminal: false,
        },
        clientInfo: { name: "wenxiang", version: "0.1.0" },
      });
      const methods = init?.authMethods || [];
      if (methods.some((m) => (m.id || m.methodId) === "cursor_login")) {
        try {
          await this.request("authenticate", { methodId: "cursor_login" });
        } catch {
          // Pre-authenticated CLI login is enough.
        }
      }
      const created = await this.request("session/new", {
        cwd: this.cwd,
        mcpServers: [],
      });
      this.sessionId = created?.sessionId || created?.session_id || "";
      if (!this.sessionId) throw new Error("ACP session/new did not return sessionId");
      const modes = created?.modes?.availableModes || init?.agentCapabilities?.sessionCapabilities?.modes?.availableModes || [];
      if (modes.some((m) => (m.id || m.modeId) === "ask")) {
        try {
          await this.request("session/set_mode", {
            sessionId: this.sessionId,
            modeId: "ask",
          });
        } catch {
          // Stay on the default mode; write tools are still rejected.
        }
      }
      this.alive = true;
      this._touch();
      return this.sessionId;
    } catch (err) {
      await this.close();
      throw err;
    }
  }

  async prompt(text, { onDelta, timeoutMs = 180_000 } = {}) {
    if (!this.alive) await this.start();
    this.onDelta = onDelta;
    this._touch();
    try {
      const result = await this.request(
        "session/prompt",
        {
          sessionId: this.sessionId,
          prompt: [{ type: "text", text }],
        },
        timeoutMs,
      );
      return result;
    } finally {
      this.onDelta = null;
      this._touch();
    }
  }

  async cancel() {
    if (!this.alive || !this.sessionId || !this.child?.stdin) return;
    try {
      this.child.stdin.write(
        `${JSON.stringify({
          jsonrpc: "2.0",
          method: "session/cancel",
          params: { sessionId: this.sessionId },
        })}\n`,
      );
    } catch {
      // Best-effort; the phone already left.
    }
    const err = new Error("cancelled");
    err.code = "cancelled";
    this._failAll(err);
  }

  async close() {
    this.alive = false;
    clearTimeout(this.idleTimer);
    this._failAll(new Error("ACP channel closed"));
    if (this.child && !this.child.killed) {
      this.child.kill("SIGTERM");
    }
    this.child = null;
    this.sessionId = "";
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
        reject(new Error(`ACP ${method} timed out`));
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

  _onLine(line) {
    const raw = String(line || "").trim();
    if (!raw) return;
    let msg;
    try {
      msg = JSON.parse(raw);
    } catch {
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
      const update = msg.params?.update;
      const text =
        update?.content?.text ||
        (update?.sessionUpdate === "agent_message_chunk" ? update?.content?.text : "");
      if (text) this.onDelta?.(text);
      return;
    }
    if (msg.method === "session/request_permission") {
      this.respond(msg.id, {
        outcome: { outcome: "selected", optionId: selectPermissionOption(msg.params) },
      });
      return;
    }
    if (msg.method === "cursor/ask_question") {
      this.respond(msg.id, { outcome: { outcome: "skipped", reason: "phone client" } });
      return;
    }
    if (msg.method === "cursor/create_plan") {
      this.respond(msg.id, { outcome: { outcome: "cancelled" } });
    }
  }

  _touch() {
    clearTimeout(this.idleTimer);
    if (!this.idleMs || !this.alive) return;
    this.idleTimer = setTimeout(() => {
      this.close();
    }, this.idleMs);
  }

  _failAll(err) {
    for (const waiter of this.pending.values()) waiter.reject(err);
    this.pending.clear();
  }

  _dead() {
    this.alive = false;
    this._failAll(new Error(this.stderr.trim() || "ACP process exited"));
    this.child = null;
  }
}

export function createSessionStore({
  spawnImpl = spawn,
  idleMs = 15 * 60 * 1000,
  now = () => new Date().toISOString(),
  resolveCommand = resolveAgentCommand,
} = {}) {
  const sessions = new Map();
  const activeByRepo = new Map();

  function repoKey(owner, repo) {
    return `${owner}/${repo}`;
  }

  function publicView(session) {
    return {
      id: session.id,
      owner: session.owner,
      repo: session.repo,
      title: session.title,
      createdAt: session.createdAt,
      updatedAt: session.updatedAt,
      active: activeByRepo.get(repoKey(session.owner, session.repo)) === session.id,
    };
  }

  function requireSession(owner, repo, id) {
    const session = sessions.get(id);
    if (!session || session.owner !== owner || session.repo !== repo) {
      const err = new Error("Session not found");
      err.status = 404;
      throw err;
    }
    return session;
  }

  function list(owner, repo) {
    const items = [...sessions.values()]
      .filter((s) => s.owner === owner && s.repo === repo)
      .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))
      .map(publicView);
    return {
      sessions: items,
      activeSessionId: activeByRepo.get(repoKey(owner, repo)) || null,
    };
  }

  function create(owner, repo) {
    const session = {
      id: randomUUID(),
      owner,
      repo,
      title: "新会话",
      createdAt: now(),
      updatedAt: now(),
      turns: 0,
      channel: null,
    };
    sessions.set(session.id, session);
    activeByRepo.set(repoKey(owner, repo), session.id);
    return publicView(session);
  }

  async function close(owner, repo, id) {
    const session = requireSession(owner, repo, id);
    if (session.channel) {
      await session.channel.close();
      session.channel = null;
    }
    sessions.delete(id);
    if (activeByRepo.get(repoKey(owner, repo)) === id) {
      const next = [...sessions.values()]
        .filter((s) => s.owner === owner && s.repo === repo)
        .sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)))[0];
      if (next) activeByRepo.set(repoKey(owner, repo), next.id);
      else activeByRepo.delete(repoKey(owner, repo));
    }
    return { closed: true, id, ...list(owner, repo) };
  }

  function resolveForChat(owner, repo, sessionId) {
    if (sessionId) {
      const session = requireSession(owner, repo, sessionId);
      activeByRepo.set(repoKey(owner, repo), session.id);
      return session;
    }
    const activeId = activeByRepo.get(repoKey(owner, repo));
    if (activeId && sessions.has(activeId)) return sessions.get(activeId);
    create(owner, repo);
    return sessions.get(activeByRepo.get(repoKey(owner, repo)));
  }

  async function prompt(session, { question, history, githubContext, cwd, onDelta }) {
    const command = resolveCommand();
    if (!command) {
      const err = new Error("Cursor ACP CLI not found");
      err.code = "acp_missing";
      throw err;
    }
    let seedHistory = session.turns === 0 && (history || []).length > 0;
    if (!session.channel?.alive) {
      if (session.channel) await session.channel.close().catch(() => {});
      session.channel = new AcpChannel({ command, cwd, spawnImpl, idleMs });
      await session.channel.start();
      seedHistory = (history || []).length > 0;
    }
    const text = buildAcpPrompt({
      question,
      history,
      githubContext,
      seedHistory,
    });
    await session.channel.prompt(text, { onDelta });
    session.turns += 1;
    if (session.title === "新会话" && question) {
      session.title = String(question).replace(/\s+/g, " ").slice(0, 32);
    }
    session.updatedAt = now();
    return { engine: "acp", sessionId: session.id };
  }

  async function cancel(session) {
    if (session?.channel) await session.channel.cancel();
  }

  return { list, create, close, resolveForChat, prompt, cancel, publicView };
}
