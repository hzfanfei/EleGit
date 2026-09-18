import { spawn } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const delayMs = Number(process.env.WENXIANG_KEEPALIVE_DELAY_MS || 2000);

function boot() {
  const child = spawn(process.execPath, ["src/server.js"], {
    cwd: root,
    stdio: "inherit",
    env: process.env,
  });
  child.on("exit", (code, signal) => {
    console.error(
      `[keep-alive] companion exited code=${code ?? "null"} signal=${signal || "-"} — restart in ${delayMs}ms`,
    );
    setTimeout(boot, delayMs);
  });
}

boot();
