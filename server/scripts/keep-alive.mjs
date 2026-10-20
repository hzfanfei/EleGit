import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLocalEnv } from "../src/env.js";
import { envWithNodeOnPath, resolveNodeExecutable } from "../src/which.js";
import {
  companionIsHealthy,
  isCompanionAlreadyRunning,
  networkLikelyUp,
  nextKeepAliveDelay,
  shouldRestartCompanion,
  shouldRestartStaleTunnel,
} from "../src/keep-alive-policy.js";
import {
  ensurePublicTunnel,
  inspectPublicTunnel,
  killPublicTunnel,
  probePublicHealth,
  publicTunnelKind,
  recoverPublicTunnel,
  shouldAutostartPublicTunnel,
} from "../src/public-tunnel.js";
import { queueRestartNoticeFile } from "../src/restart-notice.js";
import { ensureTurnRelay, turnRelayEnabled } from "../src/turn-relay-client.js";
import { configuredWorkspaceRoot } from "../src/workspace.js";

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
let tunnelChild = null;
let announcedHolding = false;
let booting = false;
let supervising = false;
let superviseAgain = false;
let lastTunnelError = "";
let publicTunnelFailStreak = 0;
let lastPublicTunnelReason = "";
let lastNetworkDownLog = 0;
let lastRelayError = "";

async function ensureTurnRelayProcess() {
  if (!turnRelayEnabled(process.env)) return;
  try {
    await ensureTurnRelay();
    lastRelayError = "";
  } catch (err) {
    const message = err.message || String(err);
    if (message !== lastRelayError) {
      lastRelayError = message;
      console.error(`[keep-alive] turn relay: ${message}`);
    }
  }
}

async function ensureTunnel() {
  if (!shouldAutostartPublicTunnel(process.env)) return;
  const state = await inspectPublicTunnel({ publicUrl, port, env: process.env });
  if (state === "mismatch") {
    await killPublicTunnel({ child: tunnelChild, env: process.env });
    tunnelChild = null;
  }
  const tunnel = await ensurePublicTunnel({ port, publicUrl, env: process.env });
  attachTunnelChild(tunnel.child);
  const kind = tunnel.kind || publicTunnelKind(process.env) || "tunnel";
  if (tunnel.reason === "already") {
    if (!announcedHolding) console.log(`${kind} already running.`);
  } else if (tunnel.started) console.log(`${kind} started.`);
  lastTunnelError = "";
}

function attachTunnelChild(child) {
  if (!child || child === tunnelChild) return;
  tunnelChild = child;
  const kind = publicTunnelKind(process.env) || "tunnel";
  tunnelChild.on("exit", () => {
    tunnelChild = null;
    console.error(`[keep-alive] ${kind} exited — starting it again`);
    publicTunnelFailStreak = 0;
    supervise();
  });
}

async function maintainPublicTunnel(localHealthy) {
  if (!shouldAutostartPublicTunnel(process.env) || !localHealthy || !publicUrl) return;

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
      console.error("[keep-alive] outbound network down — waiting (not restarting the tunnel yet)");
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

  const kind = publicTunnelKind(process.env) || "tunnel";
  console.error(`[keep-alive] public tunnel stale while companion is up — restarting ${kind}`);
  publicTunnelFailStreak = 0;
  lastPublicTunnelReason = "";
  try {
    const tunnel = await recoverPublicTunnel({
      child: tunnelChild,
      port,
      publicUrl,
      env: process.env,
    });
    attachTunnelChild(tunnel.child);
    if (tunnel.started) console.log(`${kind} started.`);
    else if (tunnel.reason === "already") console.log(`${kind} already running.`);
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
      await ensureTurnRelayProcess();
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
    if (tunnelError) {
      console.error("[keep-alive] tunnel is down; still starting companion");
    }
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
      console.error(
        `[keep-alive] companion exited code=${code ?? "null"} signal=${signal || "-"} — not restarting`,
      );
      setTimeout(supervise, pollMs);
      return;
    }
    if (Date.now() - started > 60_000) attempt = 0;
    const wait = nextKeepAliveDelay(attempt, delayMs);
    void configuredWorkspaceRoot()
      .then((root) =>
        queueRestartNoticeFile(root, {
          reason: `companion 异常退出 (code=${code ?? "null"} signal=${signal || "-"})`,
          source: "保活自动重启",
          delayMs: wait,
        }),
      )
      .catch(() => {});
    console.error(
      `[keep-alive] companion exited code=${code ?? "null"} signal=${signal || "-"} — restart in ${wait}ms`,
    );
    attempt += 1;
    setTimeout(supervise, wait);
  });
}

setInterval(supervise, pollMs);
supervise();

process.on("uncaughtException", (err) => {
  console.error(`[keep-alive] uncaughtException: ${err?.stack || err}`);
});
process.on("unhandledRejection", (err) => {
  console.error(`[keep-alive] unhandledRejection: ${err?.stack || err}`);
});
