import { loadLocalEnv } from "../src/env.js";
import { ensurePublicTunnel, publicTunnelKind } from "../src/public-tunnel.js";

loadLocalEnv();

const tunnel = await ensurePublicTunnel();
const kind = tunnel.kind || publicTunnelKind() || "tunnel";
if (tunnel.reason === "already") {
  console.log(`${kind} already running.`);
} else if (tunnel.started) {
  console.log(`${kind} started for port ${process.env.WENXIANG_PORT || 8787}.`);
}

const stop = () => {
  if (tunnel.child && !tunnel.child.killed) {
    try {
      tunnel.child.kill();
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
