import { mkdirSync, readFileSync, readdirSync, writeFileSync, existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { envWithNodeOnPath, resolveNodeExecutable, whichSync } from "./which.js";

const CURSOR_ACP_CANDIDATES = [
  { bin: "agent", args: ["acp"] },
  { bin: "cursor-agent", args: ["acp"] },
  { bin: "cursor", args: ["agent", "acp"] },
];

const CLAUDE_DEFAULT_MODEL = "MiniMax-M3";
const DEFAULT_ACP_PROMPT_TIMEOUT_MS = 15 * 60 * 1000;

export function acpPromptTimeoutMs(env = process.env) {
  const raw = String(env.WENXIANG_ACP_PROMPT_TIMEOUT_MS ?? "").trim();
  if (!raw) return DEFAULT_ACP_PROMPT_TIMEOUT_MS;
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_ACP_PROMPT_TIMEOUT_MS;
}

const WRITE_TOOL = /edit|write|delete|move|apply_patch|overwrite|commit/i;

export const DEFAULT_ACP_MODEL = "composer-2.5-fast";

export function sanitizeAcpEngine(raw) {
  const value = String(raw || "").trim().toLowerCase();
  if (value === "claude" || value === "cursor") return value;
  return null;
}

export function applyAcpEnginePreference(engine) {
  const value = sanitizeAcpEngine(engine) || "claude";
  process.env.WENXIANG_ACP_ENGINE = value;
  return value;
}

export function acpEnginePreference() {
  return sanitizeAcpEngine(process.env.WENXIANG_ACP_ENGINE) || "claude";
}

export function claudeCodeSessionOptions(model) {
  return {
    model,
    permissionMode: "plan",
    allowDangerouslySkipPermissions: true,
    settingSources: ["user"],
    settings: {
      enabledPlugins: {
        "superpowers@claude-plugins-official": false,
      },
    },
  };
}

export function acpModelId() {
  const engine = acpEnginePreference();
  const raw = String(
    process.env.WENXIANG_ACP_MODEL ||
      process.env.WENXIANG_CLAUDE_MODEL ||
      (engine === "claude" ? CLAUDE_DEFAULT_MODEL : "") ||
      process.env.WENXIANG_CURSOR_MODEL ||
      process.env.CURSOR_MODEL ||
      (engine === "claude" ? CLAUDE_DEFAULT_MODEL : DEFAULT_ACP_MODEL),
  ).trim();
  return raw || (engine === "claude" ? CLAUDE_DEFAULT_MODEL : DEFAULT_ACP_MODEL);
}

function modelArgs() {
  return ["--model", acpModelId()];
}

function claudeAgentAcpScriptPath() {
  const npmRoot = path.join(process.env.APPDATA || "", "npm", "node_modules");
  const candidates = [
    path.join(npmRoot, "@agentclientprotocol", "claude-agent-acp", "dist", "index.js"),
    path.join(npmRoot, "@zed-industries", "claude-agent-acp", "dist", "index.js"),
  ];
  return candidates.find((script) => existsSync(script)) || "";
}

export function resolveClaudeAgentCommand() {
  const script = claudeAgentAcpScriptPath();
  if (!script) return null;
  return {
    id: "claude-acp",
    bin: "claude-agent-acp",
    path: resolveNodeExecutable(),
    args: [script],
    mode: "plan",
    model: acpModelId(),
    transport: "stdio",
    provider: "claude",
  };
}

export function pickCursorVersionName(names) {
  const matched = names.filter((name) => /^\d{4}\.\d{1,2}\.\d{1,2}-[a-f0-9]+$/.test(name));
  matched.sort((a, b) => cursorVersionDate(b) - cursorVersionDate(a));
  return matched[0] || "";
}

function cursorVersionDate(name) {
  const match = /^(\d{4})\.(\d{1,2})\.(\d{1,2})-/.exec(name);
  if (!match) return 0;
  return Number(match[1] + match[2].padStart(2, "0") + match[3].padStart(2, "0"));
}

function cursorInstallDirs() {
  return [
    path.join(process.env.LOCALAPPDATA || "", "cursor-agent"),
    path.join(os.homedir(), "AppData", "Local", "cursor-agent"),
    path.join(os.homedir(), ".local", "share", "cursor-agent"),
  ].filter(Boolean);
}

function resolveCursorNodeLaunch() {
  for (const root of cursorInstallDirs()) {
    if (!root || !existsSync(root)) continue;
    const directNode = path.join(root, "node.exe");
    const directIndex = path.join(root, "index.js");
    if (existsSync(directNode) && existsSync(directIndex)) {
      return { node: directNode, index: directIndex };
    }
    const versionsDir = path.join(root, "versions");
    if (!existsSync(versionsDir)) continue;
    let names = [];
    try {
      names = readdirSync(versionsDir, { withFileTypes: true })
        .filter((entry) => entry.isDirectory())
        .map((entry) => entry.name);
    } catch {
      continue;
    }
    const version = pickCursorVersionName(names);
    if (!version) continue;
    const node = path.join(versionsDir, version, "node.exe");
    const index = path.join(versionsDir, version, "index.js");
    if (existsSync(node) && existsSync(index)) return { node, index };
  }
  return null;
}

export function resolveCursorAgentCommand() {
  const launch = resolveCursorNodeLaunch();
  const model = acpModelId();
  if (launch) {
    return {
      id: "cursor-acp",
      bin: "agent",
      path: launch.node,
      args: [launch.index, ...authArgs(), ...modelArgs(), "acp"],
      mode: "ask",
      model,
      transport: "stdio",
      provider: "cursor",
    };
  }
  for (const candidate of CURSOR_ACP_CANDIDATES) {
    const resolved = whichSync(candidate.bin);
    if (resolved) {
      return {
        id: "cursor-acp",
        bin: candidate.bin,
        path: resolved,
        args: [...authArgs(), ...modelArgs(), ...candidate.args],
        mode: "ask",
        model,
        transport: "stdio",
        provider: "cursor",
      };
    }
  }
  return null;
}

export function resolveAgentCommand() {
  const pref = acpEnginePreference();
  const claude = resolveClaudeAgentCommand();
  const cursor = resolveCursorAgentCommand();
  if (pref === "cursor") return cursor || claude;
  return claude || cursor;
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

export function preferredAcpModeIds(agentMode, isClaude) {
  if (agentMode) {
    const claude = ["bypassPermissions", "acceptEdits", "dontAsk", "agent", "default"];
    const cursor = ["agent", "code", "default", "bypassPermissions", "acceptEdits", "dontAsk"];
    return isClaude ? claude : cursor;
  }
  return ["ask", "plan"];
}

export function selectPermissionOption(params, { agentMode = false } = {}) {
  const options = Array.isArray(params?.options) ? params.options : [];
  if (agentMode) {
    const id = (opt) => String(opt.optionId || opt.id || "");
    const always = options.find((opt) => /allow/i.test(id(opt)) && /always/i.test(id(opt)));
    if (always) return id(always);
    const allow = options.find((opt) => /allow/i.test(id(opt)) && !/reject|deny/i.test(id(opt)));
    if (allow) return id(allow);
    return "allow-always";
  }
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

export function buildAcpPrompt({
  question,
  history,
  githubContext,
  seedHistory,
  spokenAnswer = false,
  agentMode = false,
  staticFiles,
}) {
  const lines = [
    "You are 问象, a local repo progress assistant running on the user's computer.",
    agentMode
      ? "You are in agent mode for this repository only. Edit files in this checkout when that is what the user asked for. Do not change other projects or global settings. Permissions for this checkout are already granted; do not stop to ask."
      : "You are in ask mode. Do not edit files, commit, or change the working tree.",
    "Answer in Simplified Chinese unless the user writes in another language.",
    "Be concise and efficient: lead with the direct answer; use short paragraphs or bullets; skip preamble, filler, and long recaps unless the user asks for detail.",
    "Do not invent commits, PRs, files, or dates. Prefer the local checkout when it disagrees with stale memory.",
  ];
  if (staticFiles?.dir) {
    lines.push(
      "",
      "=== Phone downloads ===",
      `Static directory: ${staticFiles.dir}`,
      agentMode
        ? "You may copy finished images, APKs, and other downloadable files into this directory, including subfolders. Do not put secrets, tokens, or .env files there."
        : "Do not write files. If a download already exists, you may give the user its link.",
    );
    if (staticFiles.linkTemplate) {
      lines.push(
        `When a file is in that directory, give the user this phone download link, replacing <path> with the relative path using forward slashes: ${staticFiles.linkTemplate}`,
      );
    }
  }
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
  "You are 问象·问书. Ask mode only. Do not edit files.",
  "Use Simplified Chinese unless the user uses another language.",
  "【核心】只输出答案正文；检索、对照、推理过程全部在内部完成，禁止写进回复。",
  "【开头】第一个字就要进入实质内容（情节/观点/事实/建议），禁止铺垫、承让、流程旁白、复述问题。",
  "禁止以这些开头或起句：让我/我来/我先/正在/稍等/查完/看完/读完/分析/梳理/总结/归纳/我认为/我的理解/根据书中/从本章来看/关于你的问题/需要注意的是/这本书主要/本书讲的是（空洞总起）/好的/嗯/那么/首先/简单来说/总的来说/可以说/其实/这里。",
  "Quote or paraphrase the book when helpful. Do not invent passages, characters, or events.",
  "Be concise: short sentences; no markdown, no numbered lists (第一第二), no long block quotes unless the user asks.",
];

export const BOOK_SPOKEN_ANSWER_RULES = [
  "=== 语音朗读（用户只听不说看）===",
  "Output ONLY what should be spoken aloud.",
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
      "=== Current reading chapter ===",
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

/** Claude Code billing / gateway notices that must not appear in 问书 UI. */
function isClaudeCodeBillingNotice(text) {
  const raw = String(text || "").trim();
  if (!raw) return false;
  const lower = raw.toLowerCase();
  if (/^(\*\*)?warning:/i.test(raw)) return true;
  if (/^we're changing auto mode/i.test(raw)) return true;
  if (lower.includes("auto-mode-classifier-billing")) return true;
  if (
    lower.includes("ask your gateway to implement") &&
    lower.includes("claude.com/docs") &&
    !/[\u4e00-\u9fff]/.test(raw.slice(0, 40))
  ) {
    return true;
  }
  return false;
}

export function sanitizeAcpUserVisibleText(text) {
  const raw = String(text || "");
  if (!raw) return "";
  if (isClaudeCodeBillingNotice(raw)) return "";
  let out = raw;
  out = out.replace(/\*\*Warning:\*\*[\s\S]*$/i, "");
  out = out.replace(/We're changing auto mode[\s\S]*$/i, "");
  out = out.replace(
    /\n*Nothing breaks: auto mode keeps working[\s\S]*$/i,
    "",
  );
  return out.trimEnd();
}

/** User-visible assistant text from a session/update payload (excludes reasoning channel). */
export function acpVisibleTextFromUpdate(update) {
  if (!update || typeof update !== "object") return "";
  const kind = String(update.sessionUpdate || "");
  if (ACP_HIDDEN_SESSION_UPDATES.has(kind)) return "";
  let text = "";
  if (kind === "agent_message_chunk") text = textFromAcpContentBlock(update.content);
  else if (kind === "agent_message") text = textFromAcpContentBlock(update.content);
  return sanitizeAcpUserVisibleText(text);
}

function resolveUnderCwd(cwd, rawPath) {
  const abs = path.resolve(cwd, String(rawPath || ""));
  const root = path.resolve(cwd);
  if (abs !== root && !abs.startsWith(`${root}${path.sep}`)) {
    throw new Error("path outside workspace cwd");
  }
  return abs;
}

function readTextUnderCwd(cwd, rawPath) {
  return { content: readFileSync(resolveUnderCwd(cwd, rawPath), "utf8") };
}

function writeTextUnderCwd(cwd, rawPath, content) {
  const abs = resolveUnderCwd(cwd, rawPath);
  mkdirSync(path.dirname(abs), { recursive: true });
  writeFileSync(abs, String(content ?? ""), "utf8");
  return {};
}

function claudeClaudeCodeExecutable() {
  const home = os.homedir();
  for (const candidate of [
    path.join(home, ".local", "bin", "claude.exe"),
    path.join(home, ".local", "bin", "claude"),
  ]) {
    if (existsSync(candidate)) return candidate;
  }
  return "";
}

export class AcpChannel {
  constructor({ command, cwd, spawnImpl = spawn, idleMs = 15 * 60 * 1000 } = {}) {
    this.command = command;
    this.cwd = cwd;
    this.spawnImpl = spawnImpl;
    this.idleMs = idleMs;
    this.agentMode = false;
    this.availableModes = [];
    this.child = null;
    this.sessionId = "";
    this.nextId = 1;
    this.pending = new Map();
    this.alive = false;
    this.idleTimer = null;
    this.prompting = 0;
    this.onDelta = null;
    this._lastDeltaAt = 0;
    this._usageAt = 0;
  }

  isClaudeProvider() {
    return this.command?.provider === "claude";
  }

  async start() {
    if (this.alive) return this.sessionId;
    const file = this.command.path;
    const args = this.command.args;
    const useShell = process.platform === "win32" && /\.(cmd|bat)$/i.test(file);
    let env = envWithNodeOnPath(process.env);
    if (this.isClaudeProvider()) {
      const claudeExe = claudeClaudeCodeExecutable();
      if (claudeExe) env.CLAUDE_CODE_EXECUTABLE = claudeExe;
      const nodeExe = resolveNodeExecutable();
      if (nodeExe) {
        env.NODE = nodeExe;
        env.npm_node_execpath = nodeExe;
      }
    }
    this.child = this.spawnImpl(file, args, {
      cwd: this.cwd,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
      shell: useShell,
      env,
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
          fs: {
            readTextFile: this.isClaudeProvider(),
            writeTextFile: this.isClaudeProvider(),
          },
          terminal: false,
          _meta: { parameterizedModelPicker: !this.isClaudeProvider() },
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
      const created = await this.request(
        "session/new",
        this.isClaudeProvider()
          ? {
              cwd: this.cwd,
              mcpServers: [],
              _meta: {
                claudeCode: {
                  options: claudeCodeSessionOptions(this.command?.model || acpModelId()),
                },
              },
            }
          : {
              cwd: this.cwd,
              mcpServers: [],
            },
        60_000,
      );
      this.sessionId = created?.sessionId || created?.session_id || "";
      if (!this.sessionId) throw new Error("ACP session/new did not return sessionId");
      this.availableModes =
        created?.modes?.availableModes ||
        init?.agentCapabilities?.sessionCapabilities?.modes?.availableModes ||
        [];
      await this.applySessionMode();
      await this._applyModel(created);
      this.alive = true;
      this._touch();
      return this.sessionId;
    } catch (err) {
      await this.close();
      throw err;
    }
  }

  async applySessionMode() {
    if (!this.sessionId) return;
    const order = preferredAcpModeIds(this.agentMode, this.isClaudeProvider());
    const advertised = this.availableModes
      .map((m) => String(m.id || m.modeId || ""))
      .filter(Boolean);
    for (const modeId of order) {
      if (
        advertised.length &&
        !advertised.some((id) => id.toLowerCase() === modeId.toLowerCase())
      ) {
        continue;
      }
      const exact = advertised.find((id) => id.toLowerCase() === modeId.toLowerCase()) || modeId;
      try {
        await this.request("session/set_mode", {
          sessionId: this.sessionId,
          modeId: exact,
        });
        return;
      } catch {
        if (!advertised.length) return;
      }
    }
  }

  async prompt(text, { onDelta, timeoutMs = acpPromptTimeoutMs() } = {}) {
    if (!this.alive) await this.start();
    this.prompting += 1;
    this._touch();
    try {
      if (this.isClaudeProvider()) {
        return await this._promptClaudeStream(text, { onDelta, timeoutMs });
      }
      this.onDelta = onDelta;
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
      this.prompting = Math.max(0, this.prompting - 1);
      this._touch();
    }
  }

  async _promptClaudeStream(text, { onDelta, timeoutMs = acpPromptTimeoutMs() }) {
    this.onDelta = (chunk) => {
      this._lastDeltaAt = Date.now();
      onDelta?.(chunk);
    };
    try {
      // Wait for session/prompt to finish. Do not cancel on short SSE idle: Claude Code
      // often goes silent for seconds while listing/reading files during code review.
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

  interruptPrompt() {
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
      // Best-effort; channel stays alive for the next turn.
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
      const child = this.child;
      const pid = child.pid;
      if (process.platform === "win32" && pid) {
        const taskkill = path.join(process.env.SystemRoot || "C:\\Windows", "System32", "taskkill.exe");
        const killer = spawn(taskkill, ["/PID", String(pid), "/T", "/F"], {
          windowsHide: true,
          stdio: "ignore",
        });
        killer.on("error", () => {
          try {
            child.kill();
          } catch {
            // Already gone.
          }
        });
      } else {
        try {
          this.child.kill("SIGTERM");
        } catch {
          // Already gone.
        }
      }
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
      const update = msg.params?.update || {};
      if (update.sessionUpdate === "usage_update" && this._lastDeltaAt > 0) {
        this._usageAt = Date.now();
      }
      const text = acpVisibleTextFromUpdate(update);
      if (text) this.onDelta?.(text);
      return;
    }
    if (msg.method === "fs/read_text_file") {
      try {
        this.respond(msg.id, readTextUnderCwd(this.cwd, msg.params?.path));
      } catch (err) {
        this.respond(msg.id, { error: String(err.message || err) });
      }
      return;
    }
    if (msg.method === "fs/write_text_file") {
      if (!this.agentMode) {
        this.respond(msg.id, { error: "write disabled in ask mode" });
        return;
      }
      try {
        this.respond(msg.id, writeTextUnderCwd(this.cwd, msg.params?.path, msg.params?.content));
      } catch (err) {
        this.respond(msg.id, { error: String(err.message || err) });
      }
      return;
    }
    if (msg.method === "session/request_permission") {
      this.respond(msg.id, {
        outcome: {
          outcome: "selected",
          optionId: selectPermissionOption(msg.params, { agentMode: this.agentMode }),
        },
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
    this.idleTimer = null;
    if (!this.idleMs || !this.alive || this.prompting > 0) return;
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
  let channelEpoch = 0;

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
        primedSessionId: null,
        epoch: channelEpoch,
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
    if (entry.channel?.alive && entry.epoch === channelEpoch) return { warmed: true, reused: true };
    if (entry.warmPromise) {
      await entry.warmPromise;
      return { warmed: Boolean(entry.channel?.alive), reused: true };
    }
    const epoch = channelEpoch;
    entry.epoch = epoch;
    const task = (async () => {
      let channel = null;
      try {
        if (entry.channel) await entry.channel.close().catch(() => {});
        channel = new AcpChannel({ command, cwd: root, spawnImpl, idleMs });
        await channel.start();
        if (epoch !== channelEpoch) {
          await channel.close().catch(() => {});
          return;
        }
        entry.channel = channel;
        entry.primedSessionId = null;
      } catch (err) {
        await channel?.close().catch(() => {});
        throw err;
      } finally {
        if (entry.warmPromise === task) entry.warmPromise = null;
      }
    })();
    entry.warmPromise = task;
    await task;
    return { warmed: Boolean(entry.channel?.alive), reused: false };
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

  async function prompt(session, { question, history, githubContext, bookContext, cwd, onDelta, buildPrompt, agentMode = false, staticFiles }) {
    const command = resolveCommand();
    if (!command) {
      const err = new Error("ACP agent not found");
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
    const hasHistory = (history || []).some(
      (m) => m?.content && (m.role === "user" || m.role === "assistant"),
    );
    const seedHistory = hasHistory && !entry.primedSessionId;
    const makePrompt =
      buildPrompt ||
      (bookContext ? buildBookAcpPrompt : buildAcpPrompt);
    const text = makePrompt({
      question,
      history,
      githubContext,
      bookContext,
      seedHistory,
      agentMode: Boolean(agentMode) && !bookContext,
      staticFiles: bookContext ? undefined : staticFiles,
    });
    await withRepoLock(entry, async () => {
      entry.promptingSessionId = session.id;
      const write = Boolean(agentMode) && !bookContext;
      channel.agentMode = write;
      try {
        await channel.applySessionMode();
        await channel.prompt(text, { onDelta });
        entry.primedSessionId = session.id;
      } finally {
        channel.agentMode = false;
        if (write) await channel.applySessionMode().catch(() => {});
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

  async function resetAllChannels() {
    channelEpoch += 1;
    const pending = [];
    for (const entry of repoChannels.values()) {
      entry.epoch = channelEpoch;
      if (entry.channel) pending.push(entry.channel.close().catch(() => {}));
      entry.channel = null;
      entry.warmPromise = null;
      entry.promptingSessionId = null;
      entry.primedSessionId = null;
    }
    await Promise.all(pending);
  }

  return {
    list,
    create,
    close,
    resolveForChat,
    prompt,
    cancel,
    warm,
    warmRepo,
    resetAllChannels,
    publicView,
  };
}
