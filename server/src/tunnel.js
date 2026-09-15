import { spawn } from "node:child_process";
import { whichSync } from "./ask.js";

const TRY_CLOUDFLARE = /https:\/\/[a-z0-9-]+\.trycloudflare\.com/i;

export function createTunnelManager({ port, getConfig }) {
  let child = null;
  let publicUrl = "";
  let error = "";
  let logs = "";

  function status() {
    const cfg = getConfig();
    const bin = cfg.tunnel?.bin || "cloudflared";
    return {
      running: Boolean(child && !child.killed),
      provider: cfg.tunnel?.provider || "cloudflare",
      publicUrl,
      error,
      bin,
      binFound: Boolean(whichSync(bin) || cfg.tunnel?.customCommand),
    };
  }

  function stop() {
    if (child && !child.killed) {
      child.kill("SIGTERM");
    }
    child = null;
    publicUrl = "";
    error = "";
    logs = "";
    return status();
  }

  function start() {
    if (child && !child.killed) {
      return status();
    }
    const cfg = getConfig();
    const provider = cfg.tunnel?.provider || "cloudflare";
    const custom = (cfg.tunnel?.customCommand || "").trim();
    let file;
    let args;

    if (custom) {
      const parts = custom.split(/\s+/);
      file = parts[0];
      args = parts.slice(1).map((part) => part.replaceAll("{port}", String(port)));
    } else if (provider === "cloudflare") {
      file = cfg.tunnel?.bin || "cloudflared";
      args = ["tunnel", "--url", `http://127.0.0.1:${port}`];
    } else {
      const err = new Error(
        `No tunnel command configured for provider "${provider}". Set tunnel.customCommand or install cloudflared.`,
      );
      err.status = 400;
      throw err;
    }

    const resolved = file.includes("/") ? file : whichSync(file);
    if (!resolved) {
      const err = new Error(
        `Tunnel binary "${file}" not found on PATH. Install cloudflared or set a custom command. LAN URL still works.`,
      );
      err.status = 400;
      throw err;
    }

    error = "";
    publicUrl = "";
    logs = "";
    child = spawn(resolved, args, { stdio: ["ignore", "pipe", "pipe"] });
    const onChunk = (chunk) => {
      const text = chunk.toString();
      logs = `${logs}${text}`.slice(-8000);
      const match = text.match(TRY_CLOUDFLARE) || logs.match(TRY_CLOUDFLARE);
      if (match) publicUrl = match[0];
    };
    child.stdout.on("data", onChunk);
    child.stderr.on("data", onChunk);
    child.on("error", (err) => {
      error = err.message;
      child = null;
    });
    child.on("close", (code) => {
      if (!publicUrl) {
        error = error || `Tunnel exited ${code}. ${logs.trim().slice(-400)}`;
      }
      child = null;
    });
    return status();
  }

  return { start, stop, status };
}
