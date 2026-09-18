import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { nextKeepAliveDelay, shouldRestartCompanion } from "../src/keep-alive-policy.js";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const delayMs = Number(process.env.WENXIANG_KEEPALIVE_DELAY_MS || 2000);
let attempt = 0;

function boot() {
  const child = spawn(process.execPath, ["src/server.js"], {
    cwd: root,
    stdio: "inherit",
    env: process.env,
  });
  const started = Date.now();
  child.on("exit", (code, signal) => {
    if (!shouldRestartCompanion(code, signal)) {
      process.exit(code ?? 0);
      return;
    }
    if (Date.now() - started > 60_000) attempt = 0;
    const wait = nextKeepAliveDelay(attempt, delayMs);
    console.error(
      `[keep-alive] companion exited code=${code ?? "null"} signal=${signal || "-"} — restart in ${wait}ms`,
    );
    attempt += 1;
    setTimeout(boot, wait);
  });
}

boot();
