import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import { once } from "node:events";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const serverRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

async function waitFor(fn, { timeoutMs = 8000 } = {}) {
  const start = Date.now();
  let last;
  while (Date.now() - start < timeoutMs) {
    try {
      return await fn();
    } catch (err) {
      last = err;
      await new Promise((r) => setTimeout(r, 150));
    }
  }
  throw last || new Error("timed out");
}

async function startServer() {
  const home = await mkdtemp(path.join(os.tmpdir(), "wenxiang-cors-"));
  const reservation = net.createServer();
  reservation.listen(0, "127.0.0.1");
  await once(reservation, "listening");
  const port = reservation.address().port;
  await new Promise((resolve) => reservation.close(resolve));
  const env = { ...process.env };
    delete env.GITHUB_CLIENT_ID;
    delete env.GITHUB_CLIENT_SECRET;
    delete env.WENXIANG_API_KEY;
    delete env.WENXIANG_PUBLIC_URL;
    delete env.VOLC_APP_ID;
    delete env.VOLC_ACCESS_TOKEN;
    delete env.VOLC_ACCESS_KEY;
    delete env.VOLC_API_KEY;
    delete env.DOUBAO_APP_ID;
    delete env.DOUBAO_ACCESS_KEY;
    delete env.OPENAI_API_KEY;
  const child = spawn(process.execPath, ["src/server.js"], {
    cwd: serverRoot,
    env: {
      ...env,
      WENXIANG_HOME: home,
      WENXIANG_PORT: String(port),
      WENXIANG_BIND: "127.0.0.1",
      WENXIANG_ENV_FILE: path.join(home, "missing.env"),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.resume();
  child.stderr.resume();
  async function stop() {
    if (child.exitCode !== null || child.signalCode !== null) return;
    const exited = once(child, "exit");
    child.kill("SIGTERM");
    await exited;
  }
  try {
    await waitFor(async () => {
      assert.equal(child.exitCode, null, "test server exited before becoming healthy");
      const res = await fetch(`http://127.0.0.1:${port}/health`, { signal: AbortSignal.timeout(1000) });
      assert.equal(res.status, 200);
    });
  } catch (err) {
    await stop();
    throw err;
  }
  return { stop, home, port };
}

describe("Chrome / ngrok CORS", () => {
  it("always advertises API-key and ngrok skip headers on preflight", async () => {
    const { stop, port } = await startServer();
    try {
      const origin = "http://localhost:54821";
      const res = await fetch(`http://127.0.0.1:${port}/v1/github/oauth/status?state=abc`, {
        method: "OPTIONS",
        headers: {
          Origin: origin,
          "Access-Control-Request-Method": "GET",
          "Access-Control-Request-Headers": "content-type",
        },
      });
      assert.ok(res.status === 204 || res.status === 200, `preflight status ${res.status}`);
      const allowHeaders = (res.headers.get("access-control-allow-headers") || "").toLowerCase();
      assert.match(allowHeaders, /x-wenxiang-key/);
      assert.match(allowHeaders, /ngrok-skip-browser-warning/);
    } finally {
      await stop();
    }
  });

  it("answers OPTIONS preflight for /v1 without an API key", async () => {
    const { stop, port } = await startServer();
    try {
      const origin = "http://localhost:54821";
      const res = await fetch(`http://127.0.0.1:${port}/v1/github/oauth/status?state=abc`, {
        method: "OPTIONS",
        headers: {
          Origin: origin,
          "Access-Control-Request-Method": "GET",
          "Access-Control-Request-Headers":
            "content-type,x-wenxiang-key,ngrok-skip-browser-warning",
        },
      });
      assert.ok(res.status === 204 || res.status === 200, `preflight status ${res.status}`);
      const allowOrigin = res.headers.get("access-control-allow-origin");
      assert.ok(
        allowOrigin === "*" || allowOrigin === origin,
        `Access-Control-Allow-Origin was ${allowOrigin}`,
      );
      const allowHeaders = (res.headers.get("access-control-allow-headers") || "").toLowerCase();
      assert.match(allowHeaders, /x-wenxiang-key/);
      assert.match(allowHeaders, /ngrok-skip-browser-warning/);
    } finally {
      await stop();
    }
  });

  it("reflects CORS on /v1 GET and still requires the API key", async () => {
    const { stop, home, port } = await startServer();
    try {
      const origin = "http://localhost:54821";
      const denied = await fetch(`http://127.0.0.1:${port}/v1/status`, {
        headers: {
          Origin: origin,
          "ngrok-skip-browser-warning": "true",
        },
      });
      assert.equal(denied.status, 401);
      const deniedOrigin = denied.headers.get("access-control-allow-origin");
      assert.ok(deniedOrigin === "*" || deniedOrigin === origin);

      const cfg = JSON.parse(await readFile(path.join(home, "config.json"), "utf8"));
      const ok = await fetch(`http://127.0.0.1:${port}/v1/status`, {
        headers: {
          Origin: origin,
          "X-Wenxiang-Key": cfg.apiKey,
          "ngrok-skip-browser-warning": "true",
        },
      });
      assert.equal(ok.status, 200);
      const okOrigin = ok.headers.get("access-control-allow-origin");
      assert.ok(okOrigin === "*" || okOrigin === origin);
    } finally {
      await stop();
    }
  });

});
