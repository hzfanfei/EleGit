/**
 * Planned companion restart: inbox push (while still up), brief lead time, then kill
 * the process listening on WENXIANG_PORT. keep-alive respawns server.js.
 *
 * Usage: node scripts/restart-companion.mjs [optional reason text]
 */

import { spawnSync } from "node:child_process";
import path from "node:path";
import { loadLocalEnv, repoRoot } from "../server/src/env.js";
import { publishRestartNoticeLive } from "../server/src/restart-notice.js";
import { configuredWorkspaceRoot } from "../server/src/workspace.js";

const repo = repoRoot();
loadLocalEnv(path.join(repo, ".env"));

const port = Number(process.env.WENXIANG_PORT || 8787);
const apiKey = process.env.WENXIANG_API_KEY || "";
const leadMs = Math.max(0, Number(process.env.WENXIANG_RESTART_NOTIFY_MS || 1500));
const reason = process.argv.slice(2).join(" ").trim() || "代码更新后重启";
const baseUrl = `http://127.0.0.1:${port}`;

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function killListenerOnPort(p) {
  if (process.platform === "win32") {
    const script = [
      `$c = Get-NetTCPConnection -LocalPort ${p} -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1`,
      "if ($c) { Stop-Process -Id $c.OwningProcess -Force; exit 0 }",
      "exit 1",
    ].join("; ");
    const out = spawnSync("powershell", ["-NoProfile", "-Command", script], {
      encoding: "utf8",
      windowsHide: true,
    });
    return out.status === 0;
  }
  const out = spawnSync("sh", ["-c", `fuser -k ${p}/tcp 2>/dev/null || lsof -ti :${p} | xargs -r kill -TERM`], {
    encoding: "utf8",
  });
  return out.status === 0;
}

async function handoffTurns(detach) {
  if (!apiKey) return;
  try {
    await fetch(`${baseUrl}/v1/system/handoff-turns`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Wenxiang-Key": apiKey,
      },
      body: JSON.stringify({ detach }),
    });
  } catch {
    // Older companion builds have no handoff route.
  }
}

async function main() {
  await handoffTurns(false);
  const notice = await publishRestartNoticeLive({
    baseUrl,
    apiKey,
    workspaceRoot: await configuredWorkspaceRoot(),
    reason,
    source: "计划内重启",
    delayMs: leadMs,
  });
  console.log(`[restart-companion] notice via ${notice.via}`);
  if (leadMs > 0) await sleep(leadMs);
  await handoffTurns(true);
  const killed = killListenerOnPort(port);
  if (!killed) {
    console.warn(`[restart-companion] no listener on port ${port} (keep-alive may still boot it)`);
    process.exit(0);
  }
  console.log(`[restart-companion] stopped companion on :${port}`);
}

main().catch((err) => {
  console.error(`[restart-companion] ${err.message || err}`);
  process.exit(1);
});
