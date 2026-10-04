import net from "node:net";
import readline from "node:readline";
import { spawn } from "node:child_process";
import { acpVisibleTextFromUpdate, pushAcpToolActivity, renderAcpToolLog } from "./acp.js";
import { answerReadyNotice } from "./ask.js";

/**
 * Fold one ACP stdio line into the salvage record.
 * `direction` is "in" (toward the agent) or "out" (from the agent).
 */
export function noteRelayTraffic(state, direction, line) {
  const next = {
    answer: state?.answer || "",
    promptId: state?.promptId ?? null,
    done: Boolean(state?.done),
  };
  let msg;
  try {
    msg = JSON.parse(String(line || ""));
  } catch {
    return next;
  }
  if (!msg || typeof msg !== "object") return next;
  if (direction === "in" && msg.method === "session/prompt" && msg.id != null) {
    if (next.promptId !== msg.id) next.answer = "";
    next.promptId = msg.id;
    next.done = false;
    return next;
  }
  if (direction === "out" && msg.method === "session/update") {
    const text = acpVisibleTextFromUpdate(msg.params?.update || {});
    if (text) next.answer += text;
    return next;
  }
  if (
    direction === "out" &&
    next.promptId != null &&
    msg.id === next.promptId &&
    (msg.result !== undefined || msg.error)
  ) {
    next.done = true;
  }
  return next;
}

/** Work-row text for one agent stdout line. Empty when the line is not a step. */
export function noteRelayActivity(toolLog, line) {
  let msg;
  try {
    msg = JSON.parse(String(line || ""));
  } catch {
    return "";
  }
  if (!msg || msg.method !== "session/update") return "";
  return pushAcpToolActivity(toolLog, msg.params?.update || {}) || "";
}

function consumeLines(buffer, chunk, onLine) {
  let rest = buffer + String(chunk || "");
  let idx = rest.indexOf("\n");
  while (idx >= 0) {
    onLine(rest.slice(0, idx));
    rest = rest.slice(idx + 1);
    idx = rest.indexOf("\n");
  }
  return rest;
}

/**
 * Owns Cursor/Claude ACP children outside the watched companion process.
 * When the companion socket drops, the agent keeps writing. Text already
 * produced is published about once a second; the finished answer replaces it.
 */
export function startTurnRelay({
  port = 0,
  host = "127.0.0.1",
  spawnImpl = spawn,
  publish = async () => {},
  pulseMs = 2000,
} = {}) {
  const turns = new Map();

  function send(socket, msg) {
    if (socket.destroyed) return;
    socket.write(`${JSON.stringify(msg)}\n`);
  }

  function clearScriptPulse(turn) {
    if (!turn?.scriptPulse) return;
    clearInterval(turn.scriptPulse);
    turn.scriptPulse = null;
  }

  function releaseTurn(turn) {
    clearScriptPulse(turn);
    if (!turn?.stdoutRl) return;
    turn.stdoutRl.close();
    turn.stdoutRl = null;
  }

  function endOrphan(turn, { force = false } = {}) {
    if (turn.ended) return;
    if (!force && turn.clients.size > 0) return;
    clearPartialTimer(turn);
    releaseTurn(turn);
    turn.ended = true;
    try {
      turn.child.kill?.();
    } catch {
      // Already gone.
    }
  }

  const partialMs = 800;

  function clearPartialTimer(turn) {
    if (!turn.publishTimer) return;
    clearTimeout(turn.publishTimer);
    turn.publishTimer = null;
  }

  function beginPrompt(turn) {
    // Ack belongs to the previous prompt. A restart kills the companion
    // mid-prompt; this turn must keep publishing or the phone freezes.
    turn.acked = false;
    turn.publishedFinal = false;
    turn.publishedActivity = "";
    turn.publishedAnswer = "";
    turn.activity = "";
    turn.toolLog = { items: [] };
    turn.lastPublishAt = 0;
  }

  function refreshRunningScript(turn) {
    if (turn.ended) return;
    const exposed = Boolean(turn.forceExpose) || turn.clients.size === 0;
    if (!exposed) return;
    const running = (turn.toolLog?.items || []).some((item) => item.script && item.running !== false);
    if (!running) return;
    const text = renderAcpToolLog(turn.toolLog);
    if (!text || text === turn.activity) return;
    turn.activity = text;
    maybePublish(turn);
  }

  function maybePublish(turn) {
    if (turn.publishedFinal) return;
    if (turn.acked && !turn.state.done && !turn.forceExpose && turn.clients.size > 0) return;
    const liveCompanion = turn.clients.size > 0 && !turn.acked;
    if (liveCompanion) {
      // Phone may lose SSE during a planned companion restart while the agent
      // keeps running on this relay — mirror partial progress into inbox early.
      if ((!turn.meta?.partial && !turn.forceExpose) || turn.state.done) return;
    }
    const answer = String(turn.state.answer || "").trim();
    const activity = String(turn.activity || "").trim();
    const workspaceRoot = turn.meta?.workspaceRoot;
    const exposeAnswer = Boolean(turn.state.done) || Boolean(turn.meta?.partial) || Boolean(turn.forceExpose);
    if ((!answer && !activity) || !workspaceRoot) return;
    const final = Boolean(turn.state.done);
    if (!final && !exposeAnswer && !activity) return;
    if (!final && !exposeAnswer && activity === turn.publishedActivity) return;
    if (!final && exposeAnswer && answer === turn.publishedAnswer && activity === turn.publishedActivity) return;
    const now = Date.now();
    if (!final && turn.lastPublishAt && now - turn.lastPublishAt < partialMs) {
      if (!turn.publishTimer) {
        turn.publishTimer = setTimeout(() => {
          turn.publishTimer = null;
          maybePublish(turn);
        }, partialMs - (now - turn.lastPublishAt));
        turn.publishTimer.unref?.();
      }
      return;
    }
    clearPartialTimer(turn);
    turn.lastPublishAt = now;
    turn.publishedActivity = activity;
    if (exposeAnswer) turn.publishedAnswer = answer;
    if (final) turn.publishedFinal = true;
    const notice = answerReadyNotice(exposeAnswer ? answer : "", {
      session: turn.meta.session,
      question: turn.meta.question,
      bookId: turn.meta.bookId,
      partial: !final,
      activity,
    });
    if (!notice) {
      if (final) endOrphan(turn);
      return;
    }
    const job = Promise.resolve(publish(workspaceRoot, notice));
    if (final) job.finally(() => endOrphan(turn));
  }

  function attachChild(turn) {
    const rl = readline.createInterface({ input: turn.child.stdout });
    turn.stdoutRl = rl;
    rl.on("line", (line) => {
      turn.state = noteRelayTraffic(turn.state, "out", line);
      const traced = noteRelayActivity(turn.toolLog, line);
      if (traced) turn.activity = traced;
      for (const socket of turn.clients) send(socket, { op: "stdout", key: turn.key, line });
      maybePublish(turn);
    });
    turn.child.stderr?.on("data", (chunk) => {
      const data = chunk.toString();
      for (const socket of turn.clients) send(socket, { op: "stderr", key: turn.key, data });
    });
    turn.child.on?.("exit", (code) => {
      for (const socket of turn.clients) send(socket, { op: "exit", key: turn.key, code: code ?? 0 });
      if (!turn.state.done && String(turn.state.answer || "").trim()) {
        turn.state = { ...turn.state, done: true };
      }
      releaseTurn(turn);
      turn.ended = true;
      maybePublish(turn);
    });
    turn.child.on?.("error", (err) => {
      for (const socket of turn.clients) {
        send(socket, { op: "error", key: turn.key, message: err?.message || String(err) });
      }
    });
  }

  function spawnTurn(socket, msg) {
    const key = String(msg.key || "");
    if (!key) return;
    socket.turnKey = key;
    const existing = turns.get(key);
    if (existing && !existing.ended) {
      existing.clients.add(socket);
      send(socket, { op: "spawned", key, pid: existing.child.pid || 0 });
      return;
    }
    const child = spawnImpl(msg.file, msg.args || [], {
      cwd: msg.cwd,
      env: msg.env,
      shell: Boolean(msg.shell),
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true,
    });
    const turn = {
      key,
      child,
      clients: new Set([socket]),
      state: { answer: "", promptId: null, done: false },
      activity: "",
      toolLog: { items: [] },
      pendingIn: "",
      meta: null,
      acked: false,
      published: false,
      ended: false,
    };
    const every = Math.max(200, Number(pulseMs) || 2000);
    turn.scriptPulse = setInterval(() => refreshRunningScript(turn), every);
    turn.scriptPulse.unref?.();
    turns.set(key, turn);
    attachChild(turn);
    send(socket, { op: "spawned", key, pid: child.pid || 0 });
  }

  function onClientLine(socket, line) {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (!msg || typeof msg !== "object") return;
    if (msg.op === "spawn") {
      spawnTurn(socket, msg);
      return;
    }
    const key = socket.turnKey || String(msg.key || "");
    const turn = turns.get(key);
    if (!turn) return;
    if (msg.op === "stdin") {
      turn.pendingIn = consumeLines(turn.pendingIn, msg.data, (one) => {
        const before = turn.state.promptId;
        turn.state = noteRelayTraffic(turn.state, "in", one);
        if (turn.state.promptId !== before) beginPrompt(turn);
      });
      try {
        turn.child.stdin.write(String(msg.data || ""));
      } catch {
        // Agent already closed stdin.
      }
      maybePublish(turn);
      return;
    }
    if (msg.op === "meta") {
      const next = msg.meta || null;
      const hadMeta = turn.meta != null;
      const prevQuestion = String(turn.meta?.question || "");
      const nextQuestion = String(next?.question || "");
      turn.meta = next;
      // noteTurn for the next question arrives before session/prompt. The
      // previous prompt is still done and still holds its answer. Publishing
      // now would file that answer under the new question. Freeze until the
      // new prompt clears it.
      if (hadMeta && prevQuestion !== nextQuestion) {
        turn.publishedFinal = true;
        return;
      }
      maybePublish(turn);
      return;
    }
    if (msg.op === "ack") {
      turn.acked = true;
      return;
    }
    if (msg.op === "drop") {
      // Companion is leaving on purpose. Keep the agent and publish now.
      turn.clients.delete(socket);
      if (turn.meta) turn.meta = { ...turn.meta, partial: true };
      turn.forceExpose = true;
      maybePublish(turn);
      return;
    }
    if (msg.op === "kill") {
      turn.acked = true;
      endOrphan(turn, { force: true });
    }
  }

  const sockets = new Set();
  const server = net.createServer((socket) => {
    sockets.add(socket);
    socket.on("close", () => sockets.delete(socket));
    socket.setEncoding("utf8");
    const rl = readline.createInterface({ input: socket });
    rl.on("line", (line) => onClientLine(socket, line));
    // A companion kill resets this socket. Without a listener, Node exits
    // the relay and the in-flight agent dies before the answer is published.
    socket.on("error", () => {});
    rl.on("error", () => {});
    socket.on("close", () => {
      const turn = turns.get(socket.turnKey || "");
      if (!turn) return;
      turn.clients.delete(socket);
      maybePublish(turn);
    });
  });

  return new Promise((resolve) => {
    server.listen(port, host, () => {
      const address = server.address();
      resolve({
        port: address.port,
        close() {
          for (const turn of turns.values()) {
            releaseTurn(turn);
            endOrphan(turn, { force: true });
          }
          for (const socket of sockets) socket.destroy();
          server.close();
        },
      });
    });
  });
}
