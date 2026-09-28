import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLocalEnv } from "../src/env.js";
import { envWithNodeOnPath, resolveNodeExecutable } from "../src/which.js";
import {
  companionIsHealthy,
  companionNodeArgs,
  isCompanionAlreadyRunning,
  networkLikelyUp,
  nextKeepAliveDelay,
  shouldRestartCompanion,
  shouldRestartStaleTunnel,
} from "../src/keep-alive-policy.js";
import {
  ensureNgrok,
  fetchNgrokTunnels,
  killWenxiangNgrok,
  ngrokTunnelReady,
  probePublicHealth,
  recoverNgrok,
  shouldAutostartNgrok,
} from "../src/ngrok.js";

loadLocalEnv();
process.env = envWithNodeOnPath(process.env);

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const nodeExe = resolveNodeExecutable();
const delayMs = Number(process.env.WENXIANG_KEEPALIVE_DELAY_MS || 2000);
const pollMs = Number(process.env.WENXIANG_KEEPALIVE_POLL_MS || 5000);
const port = Number(process.env.WENXIANG_PORT || 8787);
const publicUrl = process.env.WENXIANG_PUBLIC_URL;
const tunnelFailThreshold = Math.max(
  2,
  Number(process.env.WENXIANG_TUNNEL_FAIL_THRESHOLD || 3),
);
const healthUrl = `http://127.0.0.1:${port}/health`;
let attempt = 0;
let ngrokChild = null;
let announcedHolding = false;
let booting = false;
let supervising = false;
let superviseAgain = false;
let lastTunnelError = "";
let publicTunnelFailStreak = 0;
let lastPublicTunnelReason = "";
let lastNetworkDownLog = 0;

async function ensureTunnel() {
  if (!shouldAutostartNgrok(process.env)) return;
  const tunnels = await fetchNgrokTunnels();
  if (tunnels !== null && !ngrokTunnelReady(tunnels, { publicUrl, port })) {
    await killWenxiangNgrok({ child: ngrokChild, env: process.env });
    ngrokChild = null;
  }
  const ngrok = await ensureNgrok({ port, publicUrl, env: process.env });
  attachNgrokChild(ngrok.child);
  if (ngrok.reason === "already") {
    if (!announcedHolding) console.log("ngrok already running.");
  } else if (ngrok.started) console.log("ngrok started.");
  lastTunnelError = "";
}

function attachNgrokChild(child) {
  if (!child || child === ngrokChild) return;
  ngrokChild = child;
  ngrokChild.on("exit", () => {
    ngrokChild = null;
    console.error("[keep-alive] ngrok exited — starting it again");
    publicTunnelFailStreak = 0;
    supervise();
  });
}

async function maintainPublicTunnel(localHealthy) {
  if (!shouldAutostartNgrok(process.env) || !localHealthy || !publicUrl) return;

  const probe = await probePublicHealth(publicUrl);
  if (probe.ok) {
    publicTunnelFailStreak = 0;
    lastPublicTunnelReason = "";
    return;
  }

  publicTunnelFailStreak += 1;
  if (probe.reason && probe.reason !== lastPublicTunnelReason) {
    lastPublicTunnelReason = probe.reason;
    console.error(
      `[keep-alive] public tunnel probe failed (${probe.reason}), streak=${publicTunnelFailStreak}/${tunnelFailThreshold}`,
    );
  }

  const online = await networkLikelyUp();
  if (!online) {
    const now = Date.now();
    if (now - lastNetworkDownLog > 60_000) {
      lastNetworkDownLog = now;
      console.error("[keep-alive] outbound network down — waiting (not restarting ngrok yet)");
    }
    return;
  }

  if (
    !shouldRestartStaleTunnel({
      localHealthy,
      publicHealthy: false,
      failStreak: publicTunnelFailStreak,
      threshold: tunnelFailThreshold,
      networkUp: online,
    })
  ) {
    return;
  }

  console.error("[keep-alive] public tunnel stale while companion is up — restarting ngrok");
  publicTunnelFailStreak = 0;
  lastPublicTunnelReason = "";
  try {
    const ngrok = await recoverNgrok({ child: ngrokChild, port, publicUrl, env: process.env });
    attachNgrokChild(ngrok.child);
    if (ngrok.started) console.log("ngrok started.");
    else if (ngrok.reason === "already") console.log("ngrok already running.");
  } catch (err) {
    const message = err.message || String(err);
    if (message !== lastTunnelError) {
      lastTunnelError = message;
      console.error(`[keep-alive] ${message}`);
    }
  }
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
      await maintainPublicTunnel(true);
      return;
    }
    announcedHolding = false;
    publicTunnelFailStreak = 0;
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
  const child = spawn(nodeExe, companionNodeArgs(process.env), {
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
