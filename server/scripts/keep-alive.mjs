import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLocalEnv } from "../src/env.js";
import { envWithNodeOnPath, resolveNodeExecutable } from "../src/which.js";
import {
  companionIsHealthy,
  isCompanionAlreadyRunning,
  nextKeepAliveDelay,
  shouldRestartCompanion,
} from "../src/keep-alive-policy.js";
import { ensureNgrok } from "../src/ngrok.js";

loadLocalEnv();
process.env = envWithNodeOnPath(process.env);

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const nodeExe = resolveNodeExecutable();
const delayMs = Number(process.env.WENXIANG_KEEPALIVE_DELAY_MS || 2000);
const pollMs = Number(process.env.WENXIANG_KEEPALIVE_POLL_MS || 5000);
const port = Number(process.env.WENXIANG_PORT || 8787);
const healthUrl = `http://127.0.0.1:${port}/health`;
let attempt = 0;
let ngrokChild = null;
let announcedHolding = false;
let booting = false;
let supervising = false;
let superviseAgain = false;
let lastTunnelError = "";

async function ensureTunnel() {
  const ngrok = await ensureNgrok();
  if (ngrok.child && ngrok.child !== ngrokChild) {
    ngrokChild = ngrok.child;
    ngrokChild.on("exit", () => {
      ngrokChild = null;
      console.error("[keep-alive] ngrok exited — starting it again");
      supervise();
    });
  }
  if (ngrok.reason === "already") {
    if (!announcedHolding) console.log("ngrok already running.");
  } else if (ngrok.started) console.log("ngrok started.");
  lastTunnelError = "";
}

async function supervise() {
  if (supervising) {
    superviseAgain = true;
    return;
  }
  supervising = true;
  let tunnelError = null;
  try {
    try {
      await ensureTunnel();
    } catch (err) {
      tunnelError = err;
      const message = err.message || String(err);
      if (message !== lastTunnelError) {
        lastTunnelError = message;
        console.error(`[keep-alive] ${message}`);
      }
    }
    if (await companionIsHealthy(healthUrl)) {
      if (!announcedHolding) {
        console.log("[keep-alive] companion already listening, waiting until it stops");
        announcedHolding = true;
      }
      return;
    }
    announcedHolding = false;
    if (tunnelError) return;
    boot();
  } finally {
    supervising = false;
    if (superviseAgain) {
      superviseAgain = false;
      supervise();
    }
  }
}

function boot() {
  if (booting) return;
  booting = true;
  const child = spawn(nodeExe, ["src/server.js"], {
    cwd: root,
    stdio: "inherit",
    windowsHide: true,
    env: envWithNodeOnPath(process.env),
  });
  const started = Date.now();
  child.on("error", (err) => {
    booting = false;
    console.error(`[keep-alive] failed to start companion: ${err.message}`);
  });
  child.on("exit", (code, signal) => {
    booting = false;
    if (isCompanionAlreadyRunning(code)) {
      attempt = 0;
      console.error("[keep-alive] port already in use, waiting for the existing companion");
      setTimeout(supervise, pollMs);
      return;
    }
    if (!shouldRestartCompanion(code, signal)) {
      if (ngrokChild && !ngrokChild.killed) {
        try {
          ngrokChild.kill();
        } catch {
          // ignore
        }
      }
      process.exit(code ?? 0);
      return;
    }
    if (Date.now() - started > 60_000) attempt = 0;
    const wait = nextKeepAliveDelay(attempt, delayMs);
    console.error(
      `[keep-alive] companion exited code=${code ?? "null"} signal=${signal || "-"} — restart in ${wait}ms`,
    );
    attempt += 1;
    setTimeout(supervise, wait);
  });
}

setInterval(supervise, pollMs);
supervise();
