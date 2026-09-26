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

export const DEFAULT_ACP_MODEL = "grok-4.7-high-fast";

export function sanitizeAcpEngine(raw) {
  const value = String(raw || "").trim().toLowerCase();
  if (value === "claude" || value === "cursor") return value;
  return null;
}

const acpEngines = { book: "claude", repo: "claude" };

export function setAcpEnginePreferences(prefs = {}) {
  for (const scope of ["book", "repo"]) {
    const value = sanitizeAcpEngine(prefs[scope]);
    if (value) acpEngines[scope] = value;
  }
  return { ...acpEngines };
}

/** @param {"book"|"repo"} [scope] */
export function acpEnginePreference(scope = "repo") {
  const key = scope === "book" ? "book" : "repo";
  return (
    acpEngines[key] ||
    sanitizeAcpEngine(process.env.WENXIANG_ACP_ENGINE) ||
    "claude"
  );
}

export function applyAcpEnginePreference(engine) {
  const value = sanitizeAcpEngine(engine) || "claude";
  setAcpEnginePreferences({ book: value, repo: value });
  process.env.WENXIANG_ACP_ENGINE = value;
  return value;
}

export function claudeCodeSessionOptions(model) {
  return {
    model,
    permissionMode: "ask",
    allowDangerouslySkipPermissions: true,
    settingSources: ["user"],
    settings: {
      enabledPlugins: {
        "superpowers@claude-plugins-official": false,
      },
    },
  };
}

export function claudeConfiguredModel(settings) {
  return String(settings?.env?.ANTHROPIC_MODEL || "").trim();
}

export function readClaudeUserSettings(filePath = path.join(os.homedir(), ".claude", "settings.json")) {
  try {
    return JSON.parse(readFileSync(filePath, "utf8"));
  } catch {
    return null;
  }
}

export function acpModelId(env = process.env, settings, engineOverride) {
  const engine =
    sanitizeAcpEngine(engineOverride) ||
    sanitizeAcpEngine(env.WENXIANG_ACP_ENGINE) ||
    "claude";
  const explicit = String(env.WENXIANG_ACP_MODEL || "").trim();
  if (explicit) return explicit;
  if (engine === "claude") {
    const pinned = String(env.WENXIANG_CLAUDE_MODEL || "").trim();
    if (pinned) return pinned;
    const configured = claudeConfiguredModel(settings === undefined ? readClaudeUserSettings() : settings);
    return configured || CLAUDE_DEFAULT_MODEL;
  }
  return String(env.WENXIANG_CURSOR_MODEL || env.CURSOR_MODEL || "").trim() || DEFAULT_ACP_MODEL;
}

function modelArgs(enginePref) {
  return ["--model", acpModelId(process.env, undefined, enginePref)];
}

function claudeAgentAcpScriptPath() {
  const npmRoot = path.join(process.env.APPDATA || "", "npm", "node_modules");
  const candidates = [
    path.join(npmRoot, "@agentclientprotocol", "claude-agent-acp", "dist", "index.js"),
    path.join(npmRoot, "@zed-industries", "claude-agent-acp", "dist", "index.js"),
  ];
  return candidates.find((script) => existsSync(script)) || "";
}

export function resolveClaudeAgentCommand(enginePref = "claude") {
  const script = claudeAgentAcpScriptPath();
  if (!script) return null;
  return {
    id: "claude-acp",
    bin: "claude-agent-acp",
    path: resolveNodeExecutable(),
    args: [script],
    mode: "ask",
    model: acpModelId(process.env, undefined, enginePref),
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

export function resolveCursorAgentCommand(enginePref = "cursor") {
  const launch = resolveCursorNodeLaunch();
  const model = acpModelId(process.env, undefined, enginePref);
  if (launch) {
    return {
      id: "cursor-acp",
      bin: "agent",
      path: launch.node,
      args: [launch.index, ...authArgs(), ...modelArgs(enginePref), "acp"],
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
        args: [...authArgs(), ...modelArgs(enginePref), ...candidate.args],
        mode: "ask",
        model,
        transport: "stdio",
        provider: "cursor",
      };
    }
  }
  return null;
}

/** @param {"book"|"repo"} [scope] */
export function resolveAgentCommand(scope = "repo") {
  const pref = acpEnginePreference(scope);
  const claude = resolveClaudeAgentCommand("claude");
  const cursor = resolveCursorAgentCommand("cursor");
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

/** @param {"book"|"repo"} [scope] */
export function detectCursorEngine(scope = "repo") {
  return resolveAgentCommand(scope);
}

export function preferredAcpModeIds(agentMode, isClaude) {
  if (agentMode) {
    if (isClaude) return ["bypassPermissions", "acceptEdits"];
    return ["agent", "code", "default", "bypassPermissions", "acceptEdits", "dontAsk"];
  }
  return ["ask"];
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
    "【通知钩子】如你刚刚派发了后台任务并已得到最终结果，开始本轮答复前独占一行写 ===TASK_COMPLETED=== 再紧接答案正文；没有后台任务不要写这行。问象会把它推到用户的本地通知中心。",
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

export function interactionOutcome(body = {}) {
  if (body.kind === "plan") {
    if (body.accept === true) return { outcome: "accepted" };
    return { outcome: "rejected", reason: String(body.reason || "不用这个计划") };
  }
  const answers = (Array.isArray(body.answers) ? body.answers : [])
    .map((item) => ({
      questionId: String(item?.questionId || ""),
      selectedOptionIds: (Array.isArray(item?.selectedOptionIds) ? item.selectedOptionIds : [])
        .map((id) => String(id))
        .filter(Boolean),
    }))
    .filter((item) => item.questionId && item.selectedOptionIds.length);
  if (body.skip === true || !answers.length) {
    return { outcome: "skipped", reason: String(body.reason || "skipped") };
  }
  return { outcome: "answered", answers };
}

export function publicInteraction(kind, params = {}) {
  if (kind === "plan") {
    return {
      title: String(params.name || params.title || "计划"),
      overview: String(params.overview || ""),
      plan: String(params.plan || "").slice(0, 20000),
      todos: (Array.isArray(params.todos) ? params.todos : []).map((item) => ({
        id: String(item?.id || ""),
        content: String(item?.content || ""),
      })),
    };
  }
  return {
    title: String(params.title || ""),
    questions: (Array.isArray(params.questions) ? params.questions : []).map((item) => ({
      id: String(item?.id || ""),
      prompt: String(item?.prompt || ""),
      allowMultiple: item?.allowMultiple === true,
      options: (Array.isArray(item?.options) ? item.options : []).map((option) => ({
        id: String(option?.id || ""),
        label: String(option?.label || option?.id || ""),
      })),
    })),
  };
}

/** Root instructions: model must not narrate process (read/search/thinking) in the reply. */
export const BOOK_DIRECT_ANSWER_RULES = [
  "You are 问象·问书. Ask mode only. Do not edit files.",
  "Use Simplified Chinese unless the user uses another language.",
  "【核心】只输出答案正文；检索、对照、推理过程全部在内部完成，禁止写进回复。",
  "【通知钩子】如果你刚刚派发了后台任务并已得到最终结果，开始本轮答复前独占一行写 ===TASK_COMPLETED=== 再紧接答案正文；没有后台任务不要写这行。问象会把它推到用户的本地通知中心。",
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
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => {
        if (!b) return "";
        if (typeof b === "string") return b;
        if (b.text != null) return String(b.text);
        return "";
      })
      .join("");
  }
  if (typeof content === "object") {
    if (content.text != null) return String(content.text);
  }
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
  if (kind === "agent_message_chunk" || kind === "agent_message") {
    text = textFromAcpContentBlock(update.content);
  }
  if (!text && update.text != null) text = String(update.text);
  if (!text && update.delta != null) text = String(update.delta);
  return sanitizeAcpUserVisibleText(text);
}

function acpActivityPath(update) {
  const loc = update?.locations?.[0]?.path;
  if (loc) return String(loc);
  if (update?.path) return String(update.path);
  if (update?.toolCall?.path) return String(update.toolCall.path);
  return "";
}

function clipActivityLabel(text, max = 56) {
  const raw = String(text || "").replace(/\s+/g, " ").trim();
  if (raw.length <= max) return raw;
  return `${raw.slice(0, max - 1)}…`;
}

function basenameForActivity(rawPath) {
  const normalized = String(rawPath || "").replace(/\\/g, "/");
  const base = path.basename(normalized);
  return clipActivityLabel(base, 40);
}

function acpPlanActivityLabel(update) {
  const entries = Array.isArray(update?.entries) ? update.entries : [];
  const active =
    entries.find((e) => e?.status === "in_progress") ||
    entries.find((e) => e?.status === "pending");
  const line = String(active?.content || active?.description || "").trim();
  if (line) return clipActivityLabel(`规划·${line}`, 48);
  if (entries.length) return `规划 ${entries.length} 步…`;
  return "规划中…";
}

/** Short Chinese line for a tool phase (never includes reasoning text). */
function acpToolActivityLabel({ title = "", toolKind = "", filePath = "", sessionKind = "" }) {
  const t = String(title || "").trim();
  const k = String(toolKind || "").trim().toLowerCase();
  const hay = `${t} ${k}`.toLowerCase();
  const base = filePath ? basenameForActivity(filePath) : "";

  if (/grep|ripgrep|search|codebase|semantic|glob|list|rg/.test(hay) || k === "search") {
    if (t) return clipActivityLabel(`搜索·${t}`, 40);
    if (base) return `搜·${base}`;
    return "搜索中…";
  }
  if (/read|file|fetch|cat|open/.test(hay) || k === "read") {
    if (base) return `读·${base}`;
    if (t) return clipActivityLabel(`读·${t}`, 40);
    return "读文件…";
  }
  if (/write|edit|patch|delete|apply|create|replace/.test(hay) || /write|edit|delete/.test(k)) {
    if (base) return `改·${base}`;
    if (t) return clipActivityLabel(`改·${t}`, 40);
    return "改文件…";
  }
  if (/shell|terminal|bash|command|run|npm|git|exec|pnpm|node|python/.test(hay)) {
    if (t) return clipActivityLabel(`终端·${t}`, 40);
    return "跑命令…";
  }
  if (/mcp|invoke/.test(hay)) {
    return t ? clipActivityLabel(t, 40) : "扩展工具…";
  }
  if (sessionKind === "tool_call") {
    if (t) return clipActivityLabel(t, 40);
    if (base) return clipActivityLabel(base, 40);
    return "工具…";
  }
  if (sessionKind === "tool_call_update") {
    if (t) return clipActivityLabel(t, 40);
    if (base) return clipActivityLabel(base, 40);
    return "";
  }
  return "";
}

/** Short Chinese status for tool / search phases (never includes reasoning text). */
export function acpActivityLabelFromUpdate(update) {
  if (!update || typeof update !== "object") return "";
  const kind = String(update.sessionUpdate || "");
  if (
    kind === "agent_message_chunk" ||
    kind === "agent_message" ||
    kind === "usage_update" ||
    kind === "config_option_update" ||
    kind === "current_mode_update" ||
    kind === "available_commands_update" ||
    kind === "session_info_update" ||
    ACP_HIDDEN_SESSION_UPDATES.has(kind)
  ) {
    return "";
  }

  if (kind === "plan") return acpPlanActivityLabel(update);

  const filePath = acpActivityPath(update);
  const title = String(
    update.title || update.toolCall?.title || update.toolCall?.name || update.name || "",
  ).trim();
  const toolKind = String(update.toolCall?.kind || update.kind || "").trim();

  if (kind === "tool_call" || kind === "tool_call_update") {
    return acpToolActivityLabel({ title, toolKind, filePath, sessionKind: kind });
  }

  if (title) return clipActivityLabel(title, 40);
  return "";
}

export function acpActivityLabelFromFsRead(rawPath) {
  const base = basenameForActivity(rawPath);
  if (base) return `读·${base}`;
  return "读文件…";
}

const TOOL_ACTIVITY_CAP = 4;
const THOUGHT_ACTIVITY_CAP = 1000;

function capToolLog(log) {
  while (log.items.length > TOOL_ACTIVITY_CAP) {
    const drop = log.items.findIndex((entry) => entry.id !== "thought");
    if (drop < 0) {
      log.items.splice(0, log.items.length - TOOL_ACTIVITY_CAP);
      break;
    }
    log.items.splice(drop, 1);
  }
}

function mergeThoughtText(prev, next) {
  const prior = String(prev || "");
  const piece = String(next || "");
  if (!piece) return prior;
  if (!prior) return piece;
  if (piece.startsWith(prior) || prior.startsWith(piece)) {
    return piece.length >= prior.length ? piece : prior;
  }
  if (piece.includes(prior) && piece.length > prior.length) return piece;
  if (prior.endsWith(piece)) return prior;
  return `${prior}${piece}`;
}

function clipThoughtText(text) {
  const raw = String(text || "").replace(/\r/g, "").trim();
  if (raw.length <= THOUGHT_ACTIVITY_CAP) return raw;
  return `…${raw.slice(raw.length - (THOUGHT_ACTIVITY_CAP - 1))}`;
}

function thoughtPieceFromUpdate(update) {
  const fromContent = textFromAcpContentBlock(update?.content);
  const text = fromContent.trim() ? fromContent : String(update?.text || update?.delta || "");
  return sanitizeAcpUserVisibleText(text).trim();
}

function clipToolOutput(text) {
  const lines = String(text || "")
    .split(/\r?\n/)
    .map((line) => line.replace(/[ \t]+/g, " ").trim())
    .filter(Boolean)
    .slice(0, 2);
  const joined = lines.join("\n");
  if (joined.length <= 180) return joined;
  return `${joined.slice(0, 179)}…`;
}

function textFromToolContent(content) {
  const direct = textFromAcpContentBlock(content);
  if (direct.trim()) return direct;
  if (!Array.isArray(content)) return "";
  return content
    .map((block) => {
      if (!block || typeof block !== "object") return "";
      if (block.type === "diff") return "";
      if (block.content) return textFromAcpContentBlock(block.content);
      return "";
    })
    .join("");
}

function rawInputOf(update) {
  const input = update?.rawInput ?? update?.toolCall?.rawInput;
  return input && typeof input === "object" && !Array.isArray(input) ? input : {};
}

function explicitToolTitle(update) {
  return String(update?.title || update?.toolCall?.title || update?.toolCall?.name || "").trim();
}

/** Command, pattern, or path the tool actually ran. Empty when the update has no input. */
function asActivityText(value) {
  if (Array.isArray(value)) return value.map((part) => String(part ?? "")).join(" ");
  if (value == null || typeof value === "object") return "";
  return String(value);
}

function toolCommandFromUpdate(update) {
  const input = rawInputOf(update);
  if (!Object.keys(input).length) return "";
  const command = asActivityText(input.command);
  if (command) return clipActivityLabel(command, 180);
  if (input.pattern || input.globPattern) {
    const pattern = clipActivityLabel(input.pattern || input.globPattern, 120);
    const where = input.path ? basenameForActivity(input.path) : "";
    return where ? `${pattern} · ${where}` : pattern;
  }
  if (input.query) return clipActivityLabel(input.query, 180);
  if (input.searchTerm) return clipActivityLabel(input.searchTerm, 180);
  if (input.url) return clipActivityLabel(input.url, 180);
  if (input.toolName) {
    const who = input.providerIdentifier ? `${input.providerIdentifier}/` : "";
    return clipActivityLabel(`${who}${input.toolName}`, 80);
  }
  if (input.description) return clipActivityLabel(input.description, 180);
  if (Array.isArray(input.paths) && input.paths.length) {
    const first = basenameForActivity(input.paths[0]);
    return input.paths.length > 1 ? `${first} 等 ${input.paths.length} 个` : first;
  }
  if (input.path) return basenameForActivity(input.path);
  return "";
}

/** One or two lines of tool result. Never the whole file, diff, or reasoning. */
function toolOutputFromUpdate(update) {
  const raw = update?.rawOutput ?? update?.toolCall?.rawOutput;
  let text = "";
  if (typeof raw === "string") text = raw;
  else if (raw && typeof raw === "object") {
    if (raw.stdout || raw.stderr || (raw.exitCode != null && Number(raw.exitCode) !== 0)) {
      const chunks = [];
      if (raw.exitCode != null && Number(raw.exitCode) !== 0) chunks.push(`exit ${raw.exitCode}`);
      if (raw.stdout) chunks.push(String(raw.stdout));
      if (raw.stderr) chunks.push(String(raw.stderr));
      text = chunks.join("\n");
    } else if (typeof raw.content === "string") text = raw.content;
    else if (raw.error) text = String(raw.error);
    else if (raw.totalMatches != null) {
      text = raw.truncated ? `${raw.totalMatches} 处（已截断）` : `${raw.totalMatches} 处`;
    } else if (raw.resultCount != null) text = `${raw.resultCount} 条`;
    else if (raw.totalDiagnostics != null) text = `${raw.totalDiagnostics} 条诊断`;
    else if (raw.totalFiles != null) {
      text = raw.truncated ? `${raw.totalFiles} 个文件（已截断）` : `${raw.totalFiles} 个文件`;
    }
  }
  if (!text && update?.sessionUpdate === "tool_call_update") {
    text = textFromToolContent(update.content);
  }
  return clipToolOutput(text);
}

function renderToolItem(item) {
  if (item.id === "thought") {
    const body = String(item.output || "").trim();
    if (!body) return item.title || "思考";
    const preview = clipActivityLabel(body.split("\n")[0], 48);
    const head = preview ? `思考·${preview}` : "思考";
    if (body === preview) return head;
    return `${head}\n${body}`;
  }
  const lines = [];
  if (item.title) lines.push(item.title);
  if (item.command && !item.title.includes(item.command)) lines.push(item.command);
  if (item.output) lines.push(item.output);
  return lines.join("\n");
}

function renderToolLog(log) {
  return log.items.map(renderToolItem).filter(Boolean).join("\n\n");
}

/**
 * Fold one ACP tool, plan, or thought update into a short bubble log.
 * Returns the text to show, or "" when this update is not a visible step.
 * Thoughts stay out of the answer and appear here as one「思考」block.
 * The log is display-only and is never sent back to the agent.
 */
export function pushAcpToolActivity(log, update) {
  if (!log || !Array.isArray(log.items) || !update || typeof update !== "object") return "";
  const kind = String(update.sessionUpdate || "");
  if (kind === "agent_thought_chunk" || kind === "agent_thought") {
    const piece = thoughtPieceFromUpdate(update);
    if (!piece) return renderToolLog(log);
    let item = log.items.find((entry) => entry.id === "thought");
    if (!item) {
      item = { id: "thought", title: "思考", command: "", output: "", raw: "" };
      log.items.push(item);
    }
    item.raw = mergeThoughtText(item.raw || item.output, piece);
    if (item.raw.length > THOUGHT_ACTIVITY_CAP * 8) {
      item.raw = item.raw.slice(item.raw.length - THOUGHT_ACTIVITY_CAP * 8);
    }
    item.output = clipThoughtText(item.raw);
    const index = log.items.indexOf(item);
    if (index >= 0 && index !== log.items.length - 1) {
      log.items.splice(index, 1);
      log.items.push(item);
    }
    capToolLog(log);
    return renderToolLog(log);
  }
  if (kind === "plan") {
    const title = acpPlanActivityLabel(update);
    let item = log.items.find((entry) => entry.id === "plan");
    if (!item) {
      item = { id: "plan", title, command: "", output: "" };
      log.items.push(item);
    } else {
      item.title = title;
    }
    capToolLog(log);
    return renderToolLog(log);
  }
  if (kind !== "tool_call" && kind !== "tool_call_update") return "";

  const id = String(update.toolCallId || update.toolCall?.toolCallId || "");
  const title = explicitToolTitle(update) ? acpActivityLabelFromUpdate(update) : "";
  const command = toolCommandFromUpdate(update);
  const output = toolOutputFromUpdate(update);
  let item = id ? log.items.find((entry) => entry.id === id) : null;
  if (!item && kind === "tool_call_update" && log.items.length) {
    item = log.items[log.items.length - 1];
  }
  if (!item) {
    const createdTitle = title || acpActivityLabelFromUpdate(update);
    if (!createdTitle && !command && !output) return renderToolLog(log);
    item = {
      id: id || `tool-${log.items.length + 1}`,
      title: createdTitle,
      command,
      output,
    };
    log.items.push(item);
  } else {
    if (title) item.title = title;
    if (command) item.command = command;
    if (output) item.output = output;
  }
  capToolLog(log);
  return renderToolLog(log);
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
  constructor({ command, cwd, spawnImpl = spawn, idleMs = 30 * 60 * 1000 } = {}) {
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
    this.onActivity = null;
    this._toolLog = { items: [] };
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

  async prompt(text, { onDelta, onActivity, timeoutMs = acpPromptTimeoutMs() } = {}) {
    if (!this.alive) await this.start();
    this.prompting += 1;
    this._touch();
    try {
      return await this._promptStream(text, { onDelta, onActivity, timeoutMs });
    } finally {
      this.prompting = Math.max(0, this.prompting - 1);
      this._touch();
    }
  }

  async _promptStream(text, { onDelta, onActivity, timeoutMs = acpPromptTimeoutMs() }) {
    this._toolLog = { items: [] };
    this.onDelta = (chunk) => {
      this._lastDeltaAt = Date.now();
      onDelta?.(chunk);
    };
    this.onActivity = onActivity;
    onActivity?.("Agent 处理中…");
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
      this.onActivity = null;
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
      if (text) {
        this.onDelta?.(text);
        if (!this._toolLog.items.length) this.onActivity?.("");
      }
      const traced = pushAcpToolActivity(this._toolLog, update);
      if (traced) this.onActivity?.(traced);
      return;
    }
    if (msg.method === "fs/read_text_file") {
      const traced = pushAcpToolActivity(this._toolLog, {
        sessionUpdate: "tool_call",
        toolCallId: `fs-read:${String(msg.params?.path || "")}`,
        title: "Read",
        kind: "read",
        rawInput: { path: msg.params?.path || "" },
      });
      if (traced) this.onActivity?.(traced);
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
      this._relayInteraction(msg, "ask");
      return;
    }
    if (msg.method === "cursor/create_plan") {
      if (!this.agentMode) {
        this.respond(msg.id, { outcome: { outcome: "rejected", reason: "ask mode" } });
        return;
      }
      this._relayInteraction(msg, "plan");
    }
  }

  _relayInteraction(msg, kind) {
    const deliver = this.onInteraction;
    const skipped =
      kind === "plan"
        ? { outcome: "rejected", reason: "phone client" }
        : { outcome: "skipped", reason: "phone client" };
    if (!deliver) {
      this.respond(msg.id, { outcome: skipped });
      return;
    }
    Promise.resolve()
      .then(() => deliver({ kind, params: msg.params || {} }))
      .then((outcome) => {
        this.respond(msg.id, { outcome: outcome || skipped });
      })
      .catch(() => {
        this.respond(msg.id, { outcome: skipped });
      });
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
  idleMs = 30 * 60 * 1000,
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

  const channels = new Map();
  const pendingInteractions = new Map();

  function rejectPendingForSession(sessionId) {
    for (const [requestId, row] of pendingInteractions) {
      if (row.sessionId !== sessionId) continue;
      pendingInteractions.delete(requestId);
      row.reject(new Error("cancelled"));
    }
  }

  function beginInteraction(sessionId) {
    const requestId = randomUUID();
    let resolve;
    let reject;
    const promise = new Promise((res, rej) => {
      resolve = res;
      reject = rej;
    });
    pendingInteractions.set(requestId, { sessionId, resolve, reject });
    return { requestId, promise };
  }

  function answerInteraction(sessionId, requestId, body) {
    const row = pendingInteractions.get(String(requestId || ""));
    if (!row || row.sessionId !== sessionId) return false;
    pendingInteractions.delete(String(requestId || ""));
    row.resolve(interactionOutcome(body));
    return true;
  }

  function takeEntry(sessionId, cwd) {
    const root = String(cwd || "").trim();
    let entry = channels.get(sessionId);
    if (!entry || (root && entry.cwd && entry.cwd !== root)) {
      if (entry?.channel) entry.channel.close().catch(() => {});
      rejectPendingForSession(sessionId);
      entry = {
        cwd: root,
        channel: null,
        warmPromise: null,
        lock: Promise.resolve(),
        primed: false,
        announcedAgentMode: null,
        epoch: channelEpoch,
      };
      channels.set(sessionId, entry);
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

  async function warmSession(session, cwd) {
    const resolved = resolveCommand();
    const root = String(cwd || "").trim();
    if (!session?.id || !resolved || !root) return { warmed: false };
    const entry = takeEntry(session.id, root);
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
        channel = new AcpChannel({ command: resolved, cwd: root, spawnImpl, idleMs });
        await channel.start();
        if (epoch !== channelEpoch) {
          await channel.close().catch(() => {});
          return;
        }
        entry.channel = channel;
        entry.primed = false;
        entry.announcedAgentMode = null;
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

  async function warmRepo(owner, repo, cwd) {
    const id = activeByRepo.get(repoKey(owner, repo));
    const session = id && sessions.get(id);
    if (!session) return { warmed: false, reason: "no_session" };
    return warmSession(session, cwd);
  }

  async function close(owner, repo, id) {
    const session = requireSession(owner, repo, id);
    rejectPendingForSession(id);
    const entry = channels.get(id);
    if (entry?.channel) await entry.channel.close().catch(() => {});
    channels.delete(id);
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

  async function prompt(session, {
    question,
    history,
    githubContext,
    bookContext,
    cwd,
    onDelta,
    onActivity,
    onInteraction,
    buildPrompt,
    agentMode = false,
    staticFiles,
  }) {
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
    await warmSession(session, root);
    const entry = takeEntry(session.id, root);
    const channel = entry.channel;
    if (!channel?.alive) {
      const err = new Error("ACP channel failed to start");
      err.code = "acp_dead";
      throw err;
    }
    const hasHistory = (history || []).some(
      (m) => m?.content && (m.role === "user" || m.role === "assistant"),
    );
    const makePrompt =
      buildPrompt ||
      (bookContext ? buildBookAcpPrompt : buildAcpPrompt);
    const write = Boolean(agentMode) && !bookContext;
    let text;
    if (!entry.primed) {
      text = makePrompt({
        question,
        history,
        githubContext,
        bookContext,
        seedHistory: hasHistory,
        agentMode: write,
        staticFiles: bookContext ? undefined : staticFiles,
      });
    } else if (entry.announcedAgentMode !== write) {
      const note = write
        ? "You are now in agent mode for this checkout. Edit files in this checkout when that is what the user asked for."
        : "You are now in ask mode. Do not edit files or change the working tree.";
      text = `${note}\n\n${question}`;
    } else {
      text = String(question || "");
    }
    await withRepoLock(entry, async () => {
      channel.agentMode = write;
      channel.onInteraction = onInteraction
        ? async (spec) => {
            const { requestId, promise } = beginInteraction(session.id);
            onInteraction({
              kind: spec.kind,
              requestId,
              sessionId: session.id,
              ...publicInteraction(spec.kind, spec.params),
            });
            return promise;
          }
        : null;
      try {
        await channel.applySessionMode();
        await channel.prompt(text, { onDelta, onActivity });
        entry.primed = true;
        entry.announcedAgentMode = write;
      } finally {
        channel.onInteraction = null;
        channel.agentMode = false;
        if (write) await channel.applySessionMode().catch(() => {});
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
    rejectPendingForSession(session.id);
    const entry = channels.get(session.id);
    if (entry?.channel) await entry.channel.cancel();
  }

  async function cancelById(id) {
    const session = sessions.get(String(id || ""));
    if (!session) return false;
    await cancel(session);
    return true;
  }

  async function warm(session, cwd) {
    return warmSession(session, cwd);
  }

  async function resetAllChannels() {
    channelEpoch += 1;
    const pending = [];
    for (const [sessionId, entry] of channels) {
      rejectPendingForSession(sessionId);
      entry.epoch = channelEpoch;
      if (entry.channel) pending.push(entry.channel.close().catch(() => {}));
      entry.channel = null;
      entry.warmPromise = null;
      entry.primed = false;
      entry.announcedAgentMode = null;
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
    cancelById,
    answerInteraction,
    warm,
    warmRepo,
    resetAllChannels,
    publicView,
  };
}
