import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { lstat, mkdir, mkdtemp, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";

const temporaryPrefix = "wenxiang-temporary-project-v1-";

// Only remove directories created by an exited companion, never an active
// process's directory. A grace period avoids PID/startup races after a crash.
export async function cleanupAbandonedTemporaryChats({ now = Date.now(), directory = os.tmpdir(), isAlive = processAlive } = {}) {
  const root = path.resolve(directory);
  const names = await readdir(root).catch(() => []);
  for (const name of names) {
    const match = /^wenxiang-(?:chat|temporary-project)-v1-(\d+)-[a-zA-Z0-9]{6}$/.exec(name);
    if (!match) continue;
    const pid = Number(match[1]);
    if (!Number.isSafeInteger(pid) || pid <= 0 || pid === process.pid) continue;
    if (isAlive(pid)) continue;
    const target = path.resolve(root, name);
    if (path.dirname(target) !== root) continue;
    try {
      const info = await lstat(target);
      if (info.isDirectory() && !info.isSymbolicLink() && now - info.mtimeMs > 5 * 60_000) {
        await rm(target, { recursive: true, force: true, maxRetries: 3, retryDelay: 100 });
      }
    } catch { /* The directory may already be gone or in use. */ }
  }
}

function processAlive(pid) {
  try { process.kill(pid, 0); return true; }
  catch (err) { return err.code !== "ESRCH"; }
}

// A separate app-server process owns each ephemeral thread. No transcript,
// notification, relay, or project session is created by this module.
export class TemporaryChat {
  constructor({ executable, model, spawnImpl = spawn }) {
    this.executable = executable;
    this.model = model;
    this.spawnImpl = spawnImpl;
    this.pending = new Map();
    this.nextId = 0;
    this.active = null;
    this.closed = false;
  }

  async start() {
    if (!this.executable) throw new Error("找不到 Codex，无法启动临时会话");
    this.cwd = await mkdtemp(path.join(os.tmpdir(), `${temporaryPrefix}${process.pid}-`));
    await mkdir(path.join(this.cwd, "outputs"));
    await mkdir(path.join(this.cwd, ".tmp"));
    if (this.closed) { await rm(this.cwd, { recursive: true, force: true }); throw new Error("会话已关闭"); }
    this.child = this.spawnImpl(this.executable, ["app-server", "--listen", "stdio://"], {
      cwd: this.cwd, windowsHide: true, stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, TMP: path.join(this.cwd, ".tmp"), TEMP: path.join(this.cwd, ".tmp"), TMPDIR: path.join(this.cwd, ".tmp") },
    });
    this.child.stderr?.resume();
    this.child.on("error", (err) => this.fail(err));
    this.child.on("exit", () => this.fail(new Error("临时会话已结束")));
    readline.createInterface({ input: this.child.stdout }).on("line", (line) => {
      let msg;
      try { msg = JSON.parse(line); } catch { return; }
      if (msg.id !== undefined && msg.method) {
        if (this.active?.onRequest) this.active.onRequest(msg);
        else this.write({ id: msg.id, error: { code: -32601, message: "Unsupported" } });
      } else if (msg.id !== undefined) {
        const pending = this.pending.get(msg.id);
        if (!pending) return;
        this.pending.delete(msg.id);
        if (msg.error) pending.reject(new Error(msg.error.message || "Codex 请求失败"));
        else pending.resolve(msg.result);
      } else if (this.active && msg.params?.threadId === this.threadId) {
        this.active.onEvent?.(msg.method, msg.params);
        if (msg.method === "item/agentMessage/delta") this.active.onDelta(msg.params.delta || "");
        if (msg.method === "item/started") {
          const type = msg.params.item?.type;
          if (type === "reasoning") this.active.onStatus?.("正在思考");
          if (type === "commandExecution") this.active.onStatus?.("正在执行命令");
          if (type === "webSearch") this.active.onStatus?.("正在搜索");
        }
        if (msg.method === "turn/completed") {
          const turn = msg.params.turn || {};
          if (turn.status === "completed") this.active.resolve();
          else this.active.reject(new Error(turn.error?.message || (turn.status === "interrupted" ? "已停止" : "回答失败")));
        }
      }
    });
    await this.request("initialize", { clientInfo: { name: "wenxiang", title: "问象", version: "0.1.0" }, capabilities: { experimentalApi: true } });
    this.write({ method: "initialized" });
    await this.openThread(this.initialHistory || []);
  }

  async openThread(history = []) {
    const result = await this.request("thread/start", {
      cwd: this.cwd,
      ephemeral: true,
      sandbox: "read-only",
      approvalPolicy: "never",
      config: {
        project_doc_max_bytes: 0,
        mcp_servers: {},
        "features.memories": false,
        "features.multi_agent": false,
        "features.multi_agent_v2": false,
        "features.request_user_input": true,
      },
      developerInstructions: "You are 问象 in a temporary conversation. Use only this conversation and its dedicated workspace. Never access other repositories, previous conversations, or personal files. Answer in Simplified Chinese unless the user uses another language. Use concise paragraphs for mobile reading. You may create files and run tools inside this workspace when Agent mode is enabled. Put deliverables in outputs and scratch files in .tmp. Wenxiang automatically copies visible files to its static library and appends online links to the reply. Never include credentials or private inputs in deliverable files. Do not write to global static directories. No repository rules, commits or project association apply here." + (history.length ? `\nEarlier turns from THIS temporary conversation only:\n${JSON.stringify(history)}` : ""),
      ...(this.model ? { model: this.model } : {}),
    });
    if (!result?.thread?.id || result.thread.ephemeral !== true) throw new Error("Codex 未确认临时线程，无法安全启动");
    this.threadId = result.thread.id;
  }

  write(message) {
    if (!this.child?.stdin?.writable) throw new Error("临时会话已关闭");
    this.child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  request(method, params) {
    if (this.closed) return Promise.reject(new Error("临时会话已关闭"));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      try { this.write({ id, method, params }); } catch (err) { this.pending.delete(id); reject(err); }
    });
  }

  async prompt(text, onDelta, model, images = [], onStatus, options = {}) {
    if (this.busy) throw Object.assign(new Error("上一条回答尚未结束"), { status: 409 });
    this.busy = true;
    this.cancelBeforeTurn = false;
    try {
      this.startPromise ??= this.start();
      await this.startPromise;
      if (this.closed) throw new Error("临时会话已关闭");
      if (this.cancelBeforeTurn) throw new Error("已停止");
      await this.runTurn(text, onDelta, model, images, onStatus, options);
    } finally {
      this.busy = false;
    }
  }

  async runTurn(text, onDelta, model, images, onStatus, options) {
    let resolve, reject;
    const completed = new Promise((ok, fail) => { resolve = ok; reject = fail; });
    // Attach a handler immediately: a disconnect can reject before turn/start returns.
    completed.catch(() => {});
    const active = { resolve, reject, onDelta, onStatus, turnId: null, onEvent: options.onEvent, onRequest: options.onRequest };
    this.active = active;
    try {
      const input = [...(text ? [{ type: "text", text, text_elements: [] }] : []), ...images.map((url) => ({ type: "image", url }))];
      const result = await this.request("turn/start", {
        threadId: this.threadId, input,
        ...(model ? { model } : this.model ? { model: this.model } : {}),
        ...(options.effort ? { effort: options.effort } : {}),
        summary: "concise",
        serviceTier: options.fast === true ? "fast" : "default",
        sandboxPolicy: options.agentMode === true
          ? { type: "workspaceWrite", writableRoots: [this.cwd], networkAccess: true, excludeTmpdirEnvVar: true, excludeSlashTmp: true }
          : { type: "readOnly", networkAccess: true },
        approvalPolicy: "never",
      });
      active.turnId = result?.turn?.id;
      if (active.cancelRequested && active.turnId) await this.interrupt();
      await completed;
    } finally {
      if (this.active === active) this.active = null;
    }
  }

  async interrupt() {
    const active = this.active;
    if (!active) { if (this.busy) this.cancelBeforeTurn = true; return; }
    active.cancelRequested = true;
    if (active.turnId) await this.request("turn/interrupt", { threadId: this.threadId, turnId: active.turnId });
  }

  fail(err) {
    for (const item of this.pending.values()) item.reject(err);
    this.pending.clear();
    this.active?.reject(err);
  }

  async close() {
    this.closePromise ??= this.cleanup().catch((err) => { this.closePromise = null; throw err; });
    return this.closePromise;
  }

  async cleanup() {
    this.closed = true;
    this.fail(new Error("临时会话已关闭"));
    const child = this.child;
    if (child && child.exitCode === null && !child.signalCode) {
      const exited = new Promise((resolve) => child.once("exit", resolve));
      if (process.platform === "win32" && child.pid) {
        await new Promise((resolve) => {
          const killer = spawn("taskkill", ["/PID", String(child.pid), "/T", "/F"], { windowsHide: true, stdio: "ignore" });
          killer.once("error", resolve); killer.once("exit", resolve);
        });
      } else child.kill();
      let timer;
      await Promise.race([exited, new Promise((resolve) => { timer = setTimeout(resolve, 3000); timer.unref?.(); })]);
      clearTimeout(timer);
    }
    if (this.cwd) await rm(this.cwd, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

export function createTemporaryChats({ createChat, idleMs = 5 * 60_000 } = {}) {
  const sessions = new Map();
  const touch = (entry) => {
    clearTimeout(entry.timer);
    entry.timer = setTimeout(() => { void close(entry.id).catch(() => touch(entry)); }, idleMs);
    entry.timer.unref?.();
  };
  async function create() {
    const id = randomUUID();
    const entry = { id, chat: createChat() };
    sessions.set(id, entry);
    touch(entry);
    return id;
  }
  function get(id) {
    const entry = sessions.get(id);
    if (!entry || entry.chat.closed) throw Object.assign(new Error("临时会话已结束，请重新打开"), { status: 404 });
    touch(entry);
    return entry.chat;
  }
  async function close(id) {
    const entry = sessions.get(id);
    if (!entry) return;
    clearTimeout(entry.timer);
    try {
      await entry.chat.close();
      sessions.delete(id);
    } catch (err) { touch(entry); throw err; }
  }
  return { create, get, close };
}
