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

export const DEFAULT_ACP_MODEL = "composer-2.5-fast";

export function acpModelId() {
  const raw = String(process.env.WENXIANG_CURSOR_MODEL || process.env.CURSOR_MODEL || DEFAULT_ACP_MODEL).trim();
  return raw || DEFAULT_ACP_MODEL;
}

function modelArgs() {
  return ["--model", acpModelId()];
}

export function resolveAgentCommand() {
  for (const candidate of ACP_CANDIDATES) {
    const resolved = whichSync(candidate.bin);
    if (resolved) {
      return {
        id: "acp",
        bin: candidate.bin,
        path: resolved,
        args: [...authArgs(), ...modelArgs(), ...candidate.args],
        mode: "ask",
        model: acpModelId(),
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

export function buildAcpPrompt({ question, history, githubContext, seedHistory, spokenAnswer = false }) {
  const lines = [
    "You are 问象, a local repo progress assistant running on the user's computer.",
    "You are in ask mode: read the checkout and answer. Do not edit files, commit, or change the working tree.",
    "Answer in Simplified Chinese unless the user writes in another language.",
    "Be concise and efficient: lead with the direct answer; use short paragraphs or bullets; skip preamble, filler, and long recaps unless the user asks for detail.",
    "Do not invent commits, PRs, files, or dates. Prefer the local checkout when it disagrees with stale memory.",
  ];
  if (spokenAnswer) {
    lines.push(
      "",
      "【核心】只输出答案正文；读盘与推理在内部完成，禁止过程旁白与复述问题。",
      "第一个字就要进入实质内容；禁止让我/正在/查完/分析/梳理/好的/首先/简单来说 等开头。",
      ...BOOK_SPOKEN_ANSWER_RULES,
    );
  }
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

/** Root instructions: model must not narrate process (read/search/thinking) in the reply. */
export const BOOK_DIRECT_ANSWER_RULES = [
  "You are 问象·问书. Ask mode only: read INDEX.md and chapters/*.md, then answer. Do not edit files.",
  "Use Simplified Chinese unless the user uses another language.",
  "【核心】只输出答案正文；检索、对照、推理过程全部在内部完成，禁止写进回复。",
  "【开头】第一个字就要进入实质内容（情节/观点/事实/建议），禁止铺垫、承让、流程旁白、复述问题。",
  "禁止以这些开头或起句：让我/我来/我先/正在/稍等/查完/看完/读完/分析/梳理/总结/归纳/我认为/我的理解/根据书中/从本章来看/关于你的问题/需要注意的是/这本书主要/本书讲的是（空洞总起）/好的/嗯/那么/首先/简单来说/总的来说/可以说/其实/这里。",
  "Quote or paraphrase the book when helpful. Do not invent passages, characters, or events.",
  "Be concise: short sentences; no markdown, no numbered lists (第一第二), no long block quotes unless the user asks.",
];

export const BOOK_SPOKEN_ANSWER_RULES = [
  "=== 语音朗读（用户只听不说看）===",
  "Output ONLY what should be spoken aloud after silent reading of the book files.",
  "Natural colloquial Chinese; no lecture tone or padding.",
];

export const BOOK_ANSWER_FEW_SHOT = [
  "=== 正反例（风格必须像「正确」）===",
  "错：「让我查一下章节。这一章讲的是主角决定离家。」",
  "对：「这一章里主角决定离家。」",
  "错：「关于你的问题，根据书中内容，经理人容易踩的坑是…」",
  "对：「经理人容易踩的坑是 micromanage，不信任下属。」",
];

export function buildBookAcpPrompt({
  question,
  history,
  bookContext,
  seedHistory,
  currentChapter,
  spokenAnswer = false,
}) {
  const lines = [...BOOK_DIRECT_ANSWER_RULES];
  if (spokenAnswer) {
    lines.push("", ...BOOK_SPOKEN_ANSWER_RULES);
  }
  lines.push("", ...BOOK_ANSWER_FEW_SHOT);
  const chapter = String(currentChapter || "").trim();
  if (chapter) {
    lines.push(
      "",
      "=== Current reading chapter (open the matching file under chapters/ first) ===",
      chapter,
    );
  }
  if (bookContext) {
    lines.push("", "=== Book context ===", bookContext);
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
  lines.push(
    "",
    "=== 本题作答（最高优先级；违反即失败）===",
    "直接回答下列问题。不要任何前缀、过程句、元评论。第一句必须是答案内容。",
    "",
    "=== Question ===",
    question,
  );
  return lines.join("\n");
}

/** ACP session/update kinds that must never be shown to the user (internal reasoning). */
const ACP_HIDDEN_SESSION_UPDATES = new Set([
  "agent_thought_chunk",
  "agent_thought",
  "user_message_chunk",
  "user_message",
]);

function textFromAcpContentBlock(content) {
  if (!content) return "";
  if (Array.isArray(content)) {
    return content
      .filter((b) => b?.type === "text" && b.text != null)
      .map((b) => String(b.text))
      .join("");
  }
  if (content.type === "text" && content.text != null) return String(content.text);
  return "";
}

/** User-visible assistant text from a session/update payload (excludes reasoning channel). */
export function acpVisibleTextFromUpdate(update) {
  if (!update || typeof update !== "object") return "";
  const kind = String(update.sessionUpdate || "");
  if (ACP_HIDDEN_SESSION_UPDATES.has(kind)) return "";
  if (kind === "agent_message_chunk") return textFromAcpContentBlock(update.content);
  if (kind === "agent_message") return textFromAcpContentBlock(update.content);
  return "";
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
          _meta: { parameterizedModelPicker: true },
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
      await this._applyModel(created);
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

  async _applyModel(created) {
    const model = this.command?.model || acpModelId();
    const options = created?.configOptions || [];
    const modelOpt = options.find((opt) => opt.category === "model" || opt.configId === "model");
    const configId = modelOpt?.configId || "model";
    try {
      await this.request("session/set_config_option", {
        sessionId: this.sessionId,
        configId,
        value: model,
      });
    } catch {
      try {
        await this.request("session/set_model", {
          sessionId: this.sessionId,
          modelId: model,
        });
      } catch {
        // Startup --model is the reliable pin.
      }
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
      const text = acpVisibleTextFromUpdate(msg.params?.update);
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
    };
    sessions.set(session.id, session);
    activeByRepo.set(repoKey(owner, repo), session.id);
    return publicView(session);
  }

  const repoChannels = new Map();

  function repoEntry(owner, repo, cwd) {
    const key = repoKey(owner, repo);
    const root = String(cwd || "").trim();
    let entry = repoChannels.get(key);
    if (!entry || (root && entry.cwd && entry.cwd !== root)) {
      if (entry?.channel) entry.channel.close().catch(() => {});
      entry = {
        cwd: root,
        channel: null,
        warmPromise: null,
        lock: Promise.resolve(),
        promptingSessionId: null,
      };
      repoChannels.set(key, entry);
    } else if (root && !entry.cwd) {
      entry.cwd = root;
    }
    return entry;
  }

  async function withRepoLock(entry, fn) {
    const prev = entry.lock;
    let release;
    entry.lock = new Promise((resolve) => {
      release = resolve;
    });
    await prev;
    try {
      return await fn();
    } finally {
      release();
    }
  }

  async function warmRepo(owner, repo, cwd) {
    const command = resolveCommand();
    const root = String(cwd || "").trim();
    if (!command || !root) return { warmed: false };
    const entry = repoEntry(owner, repo, root);
    if (entry.channel?.alive) return { warmed: true, reused: true };
    if (entry.warmPromise) {
      await entry.warmPromise;
      return { warmed: Boolean(entry.channel?.alive), reused: true };
    }
    entry.warmPromise = (async () => {
      try {
        if (entry.channel) await entry.channel.close().catch(() => {});
        entry.channel = new AcpChannel({ command, cwd: root, spawnImpl, idleMs });
        await entry.channel.start();
      } finally {
        entry.warmPromise = null;
      }
    })();
    await entry.warmPromise;
    return { warmed: true, reused: false };
  }

  async function close(owner, repo, id) {
    const session = requireSession(owner, repo, id);
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
    const requested = String(sessionId || "").trim();
    if (requested) {
      const existing = sessions.get(requested);
      if (existing && existing.owner === owner && existing.repo === repo) {
        activeByRepo.set(repoKey(owner, repo), existing.id);
        return existing;
      }
    }
    const activeId = activeByRepo.get(repoKey(owner, repo));
    if (activeId && sessions.has(activeId)) return sessions.get(activeId);
    create(owner, repo);
    return sessions.get(activeByRepo.get(repoKey(owner, repo)));
  }

  async function prompt(session, { question, history, githubContext, bookContext, cwd, onDelta, buildPrompt }) {
    const command = resolveCommand();
    if (!command) {
      const err = new Error("Cursor ACP CLI not found");
      err.code = "acp_missing";
      throw err;
    }
    const root = String(cwd || "").trim();
    if (!root) {
      const err = new Error("checkout cwd is required for ACP");
      err.code = "checkout_missing";
      throw err;
    }
    await warmRepo(session.owner, session.repo, root);
    const entry = repoEntry(session.owner, session.repo, root);
    const channel = entry.channel;
    if (!channel?.alive) {
      const err = new Error("ACP channel failed to start");
      err.code = "acp_dead";
      throw err;
    }
    const seedHistory =
      session.turns === 0 && (history || []).filter((m) => m?.content).length > 0;
    const makePrompt =
      buildPrompt ||
      (bookContext ? buildBookAcpPrompt : buildAcpPrompt);
    const text = makePrompt({
      question,
      history,
      githubContext,
      bookContext,
      seedHistory,
    });
    await withRepoLock(entry, async () => {
      entry.promptingSessionId = session.id;
      try {
        await channel.prompt(text, { onDelta });
      } finally {
        if (entry.promptingSessionId === session.id) entry.promptingSessionId = null;
      }
    });
    session.turns += 1;
    if (session.title === "新会话" && question) {
      session.title = String(question).replace(/\s+/g, " ").slice(0, 32);
    }
    session.updatedAt = now();
    return { engine: "acp", sessionId: session.id };
  }

  async function cancel(session) {
    if (!session) return;
    const entry = repoChannels.get(repoKey(session.owner, session.repo));
    if (entry?.promptingSessionId === session.id && entry.channel) {
      await entry.channel.cancel();
    }
  }

  async function warm(session, cwd) {
    return warmRepo(session.owner, session.repo, cwd);
  }

  return { list, create, close, resolveForChat, prompt, cancel, warm, warmRepo, publicView };
}
