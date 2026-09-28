import { spawn } from "node:child_process";
import net from "node:net";
import readline from "node:readline";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
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

/** Start the detached relay once. Later companion reloads attach to it. */
export async function ensureTurnRelay() {
  if (ensuring) return ensuring;
  ensuring = (async () => {
    const file = relayInfoFile();
    if (existsSync(file)) {
      try {
        const info = JSON.parse(readFileSync(file, "utf8"));
        if (pidAlive(info.pid) && info.port) return info.port;
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
          if (info.port && pidAlive(info.pid)) return info.port;
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
      send({ op: "meta", key, meta });
    },
    ackTurn() {
      send({ op: "ack", key });
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

export function writeRelayInfo(pid, port) {
  const file = relayInfoFile();
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, JSON.stringify({ pid, port }));
}
