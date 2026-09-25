import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadLocalEnv } from "../src/env.js";
import { envWithNodeOnPath, resolveNodeExecutable } from "../src/which.js";
import { nextKeepAliveDelay, shouldRestartCompanion } from "../src/keep-alive-policy.js";
import { ensureNgrok } from "../src/ngrok.js";

loadLocalEnv();
process.env = envWithNodeOnPath(process.env);

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const nodeExe = resolveNodeExecutable();
const delayMs = Number(process.env.WENXIANG_KEEPALIVE_DELAY_MS || 2000);
let attempt = 0;
let ngrokChild = null;

async function ensureTunnel() {
  const ngrok = await ensureNgrok();
  if (ngrok.child) {
    ngrokChild = ngrok.child;
    ngrokChild.on("exit", () => {
      ngrokChild = null;
      console.error("[keep-alive] ngrok exited — will start it again with the companion");
    });
  }
  if (ngrok.reason === "already") console.log("ngrok already running.");
  else if (ngrok.started) console.log("ngrok started.");
}

function boot() {
  const child = spawn(nodeExe, ["src/server.js"], {
    cwd: root,
    stdio: "inherit",
    windowsHide: true,
    env: envWithNodeOnPath(process.env),
  });
  const started = Date.now();
  child.on("exit", (code, signal) => {
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
    setTimeout(async () => {
      try {
        await ensureTunnel();
      } catch (err) {
        console.error(`[keep-alive] ${err.message}`);
      }
      boot();
    }, wait);
  });
}

try {
  await ensureTunnel();
} catch (err) {
  console.error(`[keep-alive] ${err.message}`);
  process.exit(1);
}
boot();
