import { execFileSync, spawn } from "node:child_process";
import net from "node:net";
import readline from "node:readline";
import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { PassThrough } from "node:stream";

export const TURN_RELAY_PORT = 8791;

function relayInfoFile() {
  return path.join(os.homedir(), ".wenxiang", "turn-relay.json");
}

function pidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

let ensuring = null;
let busyRelayUntil = 0;

function envFlagOn(value) {
  const v = String(value ?? "").trim().toLowerCase();
  return v === "1" || v === "true" || v === "yes" || v === "on";
}

function envFlagOff(value) {
  const v = String(value ?? "").trim().toLowerCase();
  return v === "0" || v === "false" || v === "no" || v === "off";
}

/** Default on so Cursor agent survives planned companion restarts (8791). Set WENXIANG_TURN_RELAY=0 to disable. */
export function turnRelayEnabled(env = process.env) {
  const relay = env.WENXIANG_TURN_RELAY;
  if (envFlagOff(relay)) return false;
  if (envFlagOn(relay)) return true;
  if (envFlagOn(env.WENXIANG_DEV_WATCH)) return true;
  return true;
}

export function relaySourceStamp() {
  const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "turn-relay.js");
  try {
    return String(Math.round(statSync(script).mtimeMs));
  } catch {
    return "";
  }
}

/** Idle relay running old code should be replaced. Never replace one that still owns an agent. */
export function relayNeedsRecycle({ alive, runningStamp, sourceStamp, busy }) {
  if (!alive) return false;
  if (runningStamp && runningStamp === sourceStamp) return false;
  return !busy;
}

function relayProcessBusy(pid) {
  const id = Number(pid);
  if (!id) return false;
  try {
    if (process.platform === "win32") {
      const out = execFileSync(
        "powershell",
        [
          "-NoProfile",
          "-Command",
          `(Get-CimInstance Win32_Process -Filter "ParentProcessId=${id}").ProcessId`,
        ],
        { encoding: "utf8", windowsHide: true, timeout: 4000 },
      );
      return out.split(/\s+/).some((part) => /^\d+$/.test(part));
    }
    const out = execFileSync("ps", ["-o", "pid=", "--ppid", String(id)], {
      encoding: "utf8",
      timeout: 4000,
    });
    return out.split(/\s+/).some((part) => /^\d+$/.test(part));
  } catch {
    return true;
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Start the detached relay once. Later companion reloads attach to it. */
export async function ensureTurnRelay() {
  if (ensuring) return ensuring;
  ensuring = (async () => {
    const file = relayInfoFile();
    const sourceStamp = relaySourceStamp();
    let replacedPid = 0;
    if (existsSync(file)) {
      try {
        const info = JSON.parse(readFileSync(file, "utf8"));
        if (pidAlive(info.pid) && info.port) {
          if (Date.now() < busyRelayUntil) return info.port;
          const busy = relayProcessBusy(info.pid);
          if (busy) busyRelayUntil = Date.now() + 60_000;
          const recycle = relayNeedsRecycle({
            alive: true,
            runningStamp: String(info.sourceStamp || ""),
            sourceStamp,
            busy,
          });
          if (!recycle) return info.port;
          replacedPid = info.pid;
          try {
            process.kill(info.pid);
          } catch {
            // Already gone.
          }
          const deadline = Date.now() + 3000;
          while (pidAlive(info.pid) && Date.now() < deadline) await sleep(50);
          if (pidAlive(info.pid)) return info.port;
        }
      } catch {
        // Stale file. Start a new relay.
      }
    }
    const script = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "scripts", "turn-relay.mjs");
    const child = spawn(process.execPath, [script], {
      detached: true,
      stdio: "ignore",
      windowsHide: true,
      env: process.env,
    });
    child.unref();
    const deadline = Date.now() + 4000;
    while (Date.now() < deadline) {
      if (existsSync(file)) {
        try {
          const info = JSON.parse(readFileSync(file, "utf8"));
          if (info.port && info.pid !== replacedPid && pidAlive(info.pid)) return info.port;
        } catch {
          // File is still being written.
        }
      }
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    throw new Error("turn relay did not start");
  })();
  try {
    return await ensuring;
  } finally {
    ensuring = null;
  }
}

/**
 * Child-process stand-in whose stdio is the long-lived relay.
 * `opts.relayKey` identifies this agent so a companion restart does not own it.
 */
export function relaySpawn(file, args, opts = {}) {
  const key = String(opts.relayKey || "");
  const port = Number(opts.relayPort || TURN_RELAY_PORT);
  const socket = net.connect(port, "127.0.0.1");
  const stdout = new PassThrough();
  const stderr = new PassThrough();
  const handlers = { error: [], exit: [] };
  let opened = false;
  let lastMeta = null;
  const pending = [];
  function send(msg) {
    const line = `${JSON.stringify(msg)}\n`;
    if (!opened) pending.push(line);
    else socket.write(line);
  }
  const child = {
    pid: 0,
    killed: false,
    stdin: {
      write(chunk) {
        send({ op: "stdin", key, data: String(chunk ?? "") });
        return true;
      },
    },
    stdout,
    stderr,
    on(event, fn) {
      (handlers[event] || (handlers[event] = [])).push(fn);
      return child;
    },
    kill() {
      child.killed = true;
      send({ op: "kill", key });
    },
    noteTurn(meta) {
      lastMeta = meta || null;
      send({ op: "meta", key, meta });
    },
    ackTurn() {
      send({ op: "ack", key });
    },
    detach() {
      return new Promise((resolve) => {
        let done = false;
        const finish = () => {
          if (done) return;
          done = true;
          resolve();
        };
        if (lastMeta?.workspaceRoot) {
          send({ op: "meta", key, meta: { ...lastMeta, partial: true } });
        }
        send({ op: "drop", key });
        socket.once("close", finish);
        socket.once("error", finish);
        try {
          socket.end();
        } catch {
          finish();
        }
        setTimeout(finish, 500);
      });
    },
  };
  socket.on("connect", () => {
    opened = true;
    socket.write(`${JSON.stringify({
      op: "spawn",
      key,
      file,
      args,
      cwd: opts.cwd,
      env: opts.env,
      shell: Boolean(opts.shell),
    })}\n`);
    for (const line of pending) socket.write(line);
    pending.length = 0;
  });
  socket.on("error", (err) => {
    for (const fn of handlers.error) fn(err);
  });
  const rl = readline.createInterface({ input: socket });
  rl.on("line", (line) => {
    let msg;
    try {
      msg = JSON.parse(line);
    } catch {
      return;
    }
    if (msg.op === "spawned") child.pid = msg.pid || 0;
    else if (msg.op === "stdout") stdout.write(`${msg.line}\n`);
    else if (msg.op === "stderr") stderr.write(String(msg.data || ""));
    else if (msg.op === "exit") {
      child.killed = true;
      for (const fn of handlers.exit) fn(msg.code ?? 0);
    } else if (msg.op === "error") {
      for (const fn of handlers.error) fn(new Error(msg.message || "turn relay error"));
    }
  });
  return child;
}

export function writeRelayInfo(pid, port, sourceStamp = "") {
  const file = relayInfoFile();
  mkdirSync(path.dirname(file), { recursive: true });
  const payload = { pid, port };
  if (sourceStamp) payload.sourceStamp = sourceStamp;
  writeFileSync(file, JSON.stringify(payload));
}
