import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createTunnelHealth } from "../src/tunnel-health.js";

describe("tunnel health", () => {
  it("records public /health reachability", async () => {
    const calls = [];
    const health = createTunnelHealth({
      getPublicUrl: () => "https://demo.ngrok-free.dev",
      intervalMs: 60_000,
      fetchImpl: async (url, opts) => {
        calls.push({ url, headers: opts?.headers });
        return { ok: true, status: 200 };
      },
    });
    await health.probe();
    assert.equal(health.status().reachable, true);
    assert.match(calls[0].url, /demo\.ngrok-free\.dev\/health/);
    assert.equal(calls[0].headers["ngrok-skip-browser-warning"], "true");
    health.stop();
  });

  it("marks the tunnel down when the probe throws", async () => {
    const health = createTunnelHealth({
      getPublicUrl: () => "https://demo.ngrok-free.dev",
      intervalMs: 60_000,
      fetchImpl: async () => {
        throw new Error("handshake failed");
      },
    });
    await health.probe();
    assert.equal(health.status().reachable, false);
    assert.match(health.status().error, /handshake/i);
    health.stop();
  });
});
