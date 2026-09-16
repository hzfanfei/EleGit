import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const serverRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = path.join(serverRoot, "..");

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
  const port = 18788;
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
  await waitFor(async () => {
    const res = await fetch(`http://127.0.0.1:${port}/health`);
    assert.equal(res.status, 200);
  });
  return { child, home, port };
}

describe("Chrome / ngrok CORS", () => {
  it("always advertises API-key and ngrok skip headers on preflight", async () => {
    const { child, port } = await startServer();
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
      child.kill("SIGTERM");
    }
  });

  it("answers OPTIONS preflight for /v1 without an API key", async () => {
    const { child, port } = await startServer();
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
      child.kill("SIGTERM");
    }
  });

  it("reflects CORS on /v1 GET and still requires the API key", async () => {
    const { child, home, port } = await startServer();
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
      child.kill("SIGTERM");
    }
  });

  it("Flutter HTTP client sends the ngrok skip header on every request", async () => {
    const src = await readFile(path.join(repoRoot, "app/lib/api/wenxiang_api.dart"), "utf8");
    assert.match(src, /'ngrok-skip-browser-warning'\s*:\s*'true'/);
    assert.match(src, /http\.get\(_uri\('\/health'\),\s*headers:\s*_headers/);
    assert.match(src, /\.\.\._headers/);
  });
});
