import assert from "node:assert/strict";
import { mkdtemp, readFile } from "node:fs/promises";
import { spawn } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

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

describe("companion HTTP", () => {
  it("serves health and protects /v1", async () => {
    const home = await mkdtemp(path.join(os.tmpdir(), "wenxiang-"));
    const port = 18787;
    const child = spawn(process.execPath, ["src/server.js"], {
      cwd: root,
      env: {
        ...process.env,
        WENXIANG_HOME: home,
        WENXIANG_PORT: String(port),
        WENXIANG_BIND: "127.0.0.1",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    try {
      await waitFor(async () => {
        const res = await fetch(`http://127.0.0.1:${port}/health`);
        assert.equal(res.status, 200);
        const body = await res.json();
        assert.equal(body.service, "wenxiang");
      });

      const denied = await fetch(`http://127.0.0.1:${port}/v1/status`);
      assert.equal(denied.status, 401);

      const cfg = JSON.parse(await readFile(path.join(home, "config.json"), "utf8"));
      const ok = await fetch(`http://127.0.0.1:${port}/v1/status`, {
        headers: { "X-Wenxiang-Key": cfg.apiKey },
      });
      assert.equal(ok.status, 200);
      const status = await ok.json();
      assert.equal(status.github.connected, false);
      assert.equal(status.github.oauthReady, false);
      assert.ok(Array.isArray(status.github.callbackUrls));
      assert.ok(String(status.workspace.root).length > 0);
      assert.ok(Array.isArray(status.lanUrls));
    } finally {
      child.kill("SIGTERM");
    }
  });
});
