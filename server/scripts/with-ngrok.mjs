import { loadLocalEnv } from "../src/env.js";
import { ensureNgrok } from "../src/ngrok.js";

loadLocalEnv();

const ngrok = await ensureNgrok();
if (ngrok.reason === "already") {
  console.log("ngrok already running.");
} else if (ngrok.started) {
  console.log(`ngrok started for port ${process.env.WENXIANG_PORT || 8787}.`);
}

const stop = () => {
  if (ngrok.child && !ngrok.child.killed) {
    try {
      ngrok.child.kill();
    } catch {
      // ignore
    }
  }
};
process.on("exit", stop);
process.on("SIGINT", () => {
  stop();
  process.exit(0);
});
process.on("SIGTERM", () => {
  stop();
  process.exit(0);
});

await import("../src/server.js");
