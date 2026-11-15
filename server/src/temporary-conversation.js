import { randomUUID } from "node:crypto";
import { EventEmitter, on } from "node:events";
import { lstat, readdir, realpath } from "node:fs/promises";
import path from "node:path";

const terminal = new Set(["completed", "failed", "stopped"]);
const conflict = (message) => Object.assign(new Error(message), { status: 409 });

export function validateTemporaryInput(body = {}) {
  const message = String(body.message || "").trim();
  const images = body.images ?? [];
  if (!Array.isArray(images) || images.length > 4 || images.some((image) => typeof image !== "string" || image.length > 5_592_430 || !/^data:image\/(jpeg|png|webp|gif);base64,[A-Za-z0-9+/]+={0,2}$/.test(image))) {
    throw Object.assign(new Error("图片格式或大小不正确"), { status: 400 });
  }
  if ((!message && !images.length) || message.length > 100_000) throw Object.assign(new Error("请输入问题（最多十万字）"), { status: 400 });
  return {
    message, images,
    model: typeof body.model === "string" ? body.model.slice(0, 200) : undefined,
    effort: typeof body.effort === "string" ? body.effort.slice(0, 32) : undefined,
    fast: body.fast === true, agentMode: body.agentMode === true, planning: body.planning === true,
  };
}

// All queue, recovery and decision state is volatile. Never goes through the
// project session store, inbox, server content logs or static file library.
export class TemporaryConversation {
  constructor(chat) {
    this.chat = chat;
    this.turns = [];
    this.files = [];
    this.events = new EventEmitter();
    this.downloadKey = randomUUID();
    this.requests = new Map();
    this.closed = false;
    this.version = 0;
  }

  changed() { this.version++; this.events.emit("change"); }
  snapshot() {
    return { version: this.version, busy: Boolean(this.current), files: this.files, turns: this.turns.map(({ options, images, ...turn }) => ({ ...turn, imageCount: images.length })) };
  }

  submit(body) {
    if (this.closed) throw conflict("临时会话已结束");
    const id = String(body.id || randomUUID()).slice(0, 128);
    const found = this.turns.find((turn) => turn.id === id);
    if (found) return found; // A dropped POST can safely be retried.
    if (this.turns.filter((t) => t.status === "queued").length >= 30) throw conflict("排队问题已达上限");
    const options = validateTemporaryInput(body);
    if (!this.turns.length && Array.isArray(body.history)) {
      const history = body.history.filter((m) => ["user", "assistant"].includes(m?.role) && typeof m.content === "string").slice(-100);
      if (JSON.stringify(history).length > 200_000) throw Object.assign(new Error("临时对话上下文过长"), { status: 400 });
      this.chat.initialHistory = history;
    }
    const turn = { id, question: options.message, images: options.images, options, answer: "", status: "queued", steps: [], decision: null, createdAt: Date.now() };
    this.turns.push(turn);
    this.changed();
    void this.drain();
    return turn;
  }

  async drain() {
    if (this.current || this.editing || this.closed) return;
    const turn = this.turns.find((t) => t.status === "queued");
    if (!turn) return;
    this.current = turn;
    turn.status = "running";
    turn.startedAt = Date.now();
    this.changed();
    let finalStatus = "completed";
    try {
      const opts = turn.options;
      await this.chat.prompt(opts.planning ? `请先制定计划，不执行实际修改。完成后等待用户确认。\n${turn.question}` : turn.question,
        (delta) => { turn.answer += delta; this.changed(); }, opts.model, opts.images,
        (detail) => { turn.activity = detail; this.changed(); }, {
          ...opts,
          agentMode: opts.agentMode && !opts.planning,
          onEvent: (method, params) => this.activity(turn, method, params),
          onRequest: (request) => this.requestDecision(turn, request),
        });
      if (opts.planning || turn.proposedPlan) turn.decision = { type: "plan", requestId: `plan-${turn.id}`, title: "确认执行计划", plan: turn.proposedPlan || turn.answer };
    } catch (err) {
      finalStatus = turn.stopping || this.closed ? "stopped" : "failed";
      if (finalStatus === "failed") turn.error = err.message || "回答失败";
    } finally {
      for (const [id, request] of this.requests) {
        if (request.turn === turn) this.requests.delete(id);
      }
      if (!turn.options.planning && !turn.proposedPlan) turn.decision = null;
      turn.finishedAt = Date.now();
      for (const step of turn.steps) if (!step.finishedAt) step.finishedAt = turn.finishedAt;
      await this.scanFiles().catch(() => {});
      turn.status = finalStatus;
      this.current = null;
      this.changed();
      if (!this.closed) void this.drain();
    }
  }

  activity(turn, method, params) {
    const item = params.item;
    if ((method === "item/started" || method === "item/completed") && item) {
      const titles = { reasoning: "思考", commandExecution: "执行命令", webSearch: "搜索", fileChange: "修改文件", plan: "计划", mcpToolCall: "调用工具" };
      if (item.type === "agentMessage" || item.type === "userMessage") return;
      if (item.type === "plan" && method === "item/completed") turn.proposedPlan = item.text || "";
      const id = item.id || `${item.type}-${turn.steps.length}`;
      let step = turn.steps.find((s) => s.id === id);
      if (!step) {
        step = { id, title: titles[item.type] || item.type, startedAt: Date.now(), detail: "", output: "" };
        turn.steps.push(step);
      }
      step.detail = String(item.command || item.query || item.tool || step.detail || "").slice(0, 12000);
      if (item.aggregatedOutput) step.output = String(item.aggregatedOutput).slice(-32000);
      if (item.changes) step.detail = item.changes.map((c) => c.path).join("\n");
      if (item.summary) step.detail = Array.isArray(item.summary) ? item.summary.map((s) => typeof s === "string" ? s : s.text || "").join("\n") : String(item.summary);
      if (method === "item/completed") { step.finishedAt = Date.now(); step.exitCode = item.exitCode; }
    } else if (method === "item/commandExecution/outputDelta" || method === "item/reasoning/summaryTextDelta" || method === "item/plan/delta") {
      const step = turn.steps.find((s) => s.id === params.itemId);
      if (step) {
        const key = method.includes("outputDelta") ? "output" : "detail";
        step[key] = (step[key] + (params.delta || "")).slice(-32000);
      }
    } else if (method === "turn/plan/updated") {
      turn.plan = params.plan;
    }
    this.changed();
  }

  requestDecision(turn, request) {
    if (request.method !== "item/tool/requestUserInput") {
      // Never offer a UI action that could grant access outside this workspace.
      this.chat.write({ id: request.id, error: { code: -32601, message: "Temporary workspace only; elevated access is unavailable" } });
      return;
    }
    const questions = request.params?.questions || [];
    const requestId = String(request.id);
    this.requests.set(requestId, { wireId: request.id, turn, questions });
    turn.decision = {
      type: "ask", requestId, title: "需要你选一下",
      questions: questions.map((q) => ({ id: q.id, prompt: q.question, options: (q.options || []).map((o) => ({ id: o.label, label: o.label })) })),
    };
    this.changed();
  }

  decide(body) {
    const turn = this.turns.find((t) => t.decision?.requestId === body.requestId);
    if (!turn) throw conflict("这个确认已失效");
    if (turn.decision.type === "plan") {
      turn.decision = null;
      if (body.accept === true) turn.continuationId = this.submit({ ...turn.options, id: randomUUID(), message: "按刚才的计划执行。", planning: false, agentMode: true, images: [] }).id;
    } else {
      const request = this.requests.get(body.requestId);
      if (!request) throw conflict("这个问题已失效");
      const answers = {};
      for (const question of request.questions) {
        const answer = (body.answers || []).find((a) => a.questionId === question.id);
        answers[question.id] = { answers: body.skip ? [] : (answer?.selectedOptionIds || []).map(String) };
      }
      this.chat.write({ id: request.wireId, result: { answers } });
      this.requests.delete(body.requestId);
      turn.decision = null;
    }
    this.changed();
  }

  async edit(id, body) {
    const index = this.turns.findIndex((t) => t.id === id);
    const turn = this.turns[index];
    if (!turn) throw Object.assign(new Error("问题不存在"), { status: 404 });
    if (turn.status === "queued") {
      const options = validateTemporaryInput({ ...turn.options, ...body });
      turn.options = options; turn.question = options.message; turn.images = options.images;
      this.changed(); return;
    }
    if (this.current || this.editing) throw conflict("请先停止当前回答");
    const options = validateTemporaryInput({ ...turn.options, ...body });
    this.editing = true;
    try {
      const history = this.turns.slice(0, index).flatMap((t) => [
        { role: "user", content: t.question },
        ...(t.answer ? [{ role: "assistant", content: t.answer }] : []),
      ]);
      if (this.chat.threadId) await this.chat.openThread(history);
      this.turns.splice(index);
      this.submit({ ...options, id: randomUUID() });
    } finally { this.editing = false; void this.drain(); }
  }

  remove(id) {
    const index = this.turns.findIndex((t) => t.id === id && t.status === "queued");
    if (index < 0) throw conflict("只能移出排队中的问题");
    this.turns.splice(index, 1); this.changed();
  }

  async stop(turnId) {
    if (turnId && this.current?.id !== turnId) return;
    if (!this.current) { await this.chat.interrupt(); return; }
    this.current.stopping = true;
    await this.chat.interrupt();
    this.changed();
  }

  async scanFiles() {
    if (!this.chat.cwd || this.closed) return;
    const files = [];
    const visit = async (directory, prefix = "") => {
      for (const entry of await readdir(directory, { withFileTypes: true })) {
        if (files.length >= 200 || entry.name.startsWith(".") || entry.isSymbolicLink()) continue;
        const relative = prefix + entry.name;
        const abs = path.join(directory, entry.name);
        if (entry.isDirectory()) await visit(abs, relative + "/");
        else if (entry.isFile()) {
          const info = await lstat(abs);
          files.push({ path: relative, size: info.size });
        }
      }
    };
    await visit(this.chat.cwd);
    this.files = files;
  }

  async resolveFile(relative) {
    if (!this.chat.cwd || this.closed) throw Object.assign(new Error("文件已清理"), { status: 404 });
    const root = await realpath(this.chat.cwd);
    const target = path.resolve(root, relative);
    const within = (abs) => { const rel = path.relative(root, abs); return rel && rel !== ".." && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel); };
    if (!within(target)) throw Object.assign(new Error("无效文件路径"), { status: 403 });
    const resolved = await realpath(target);
    if (!within(resolved) || !(await lstat(resolved)).isFile()) throw Object.assign(new Error("无效文件路径"), { status: 403 });
    return resolved;
  }

  async *voice(question, signal) {
    if (signal?.aborted || this.closed) return;
    const turn = this.submit({ ...this.voiceOptions, message: question, id: randomUUID() });
    let offset = 0;
    const abort = () => { if (this.current === turn) void this.stop().catch(() => {}); else if (turn.status === "queued") this.remove(turn.id); };
    signal?.addEventListener("abort", abort, { once: true });
    try {
      // Register before inspecting state, so a completion cannot be missed.
      const controller = new AbortController();
      const forwardAbort = () => controller.abort();
      signal?.addEventListener("abort", forwardAbort, { once: true });
      const changes = on(this.events, "change", { signal: controller.signal });
      try {
        yield { type: "start", engine: "codex" };
        while (!this.closed && !signal?.aborted) {
          if (turn.answer.length > offset) { yield { type: "delta", text: turn.answer.slice(offset), engine: "codex" }; offset = turn.answer.length; }
          if (terminal.has(turn.status)) {
            if (turn.error) throw new Error(turn.error);
            yield { type: "done", text: turn.answer, engine: "codex" }; return;
          }
          await changes.next();
        }
      } catch (err) { if (!signal?.aborted) throw err; }
      finally { controller.abort(); signal?.removeEventListener("abort", forwardAbort); }
    } finally { signal?.removeEventListener("abort", abort); }
  }

  async close() {
    this.closed = true;
    await this.chat.close();
    this.turns.length = 0; this.files.length = 0; this.requests.clear();
    this.changed();
    this.events.removeAllListeners();
  }
}
