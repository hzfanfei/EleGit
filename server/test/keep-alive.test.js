import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  COMPANION_ALREADY_RUNNING,
  companionIsHealthy,
  isCompanionAlreadyRunning,
  nextKeepAliveDelay,
  shouldRestartCompanion,
} from "../src/keep-alive-policy.js";

describe("keep-alive policy", () => {
  it("does not restart a clean exit", () => {
    assert.equal(shouldRestartCompanion(0, null), false);
    assert.equal(shouldRestartCompanion(1, null), true);
    assert.equal(shouldRestartCompanion(null, "SIGTERM"), true);
  });

  it("waits instead of crash-looping when a companion is already bound", () => {
    assert.equal(isCompanionAlreadyRunning(COMPANION_ALREADY_RUNNING), true);
    assert.equal(shouldRestartCompanion(COMPANION_ALREADY_RUNNING, null), false);
  });

  it("treats only a wenxiang health payload as already up", async () => {
    const ok = await companionIsHealthy("http://127.0.0.1:9/health", {
      fetchImpl: async () => ({
        ok: true,
        json: async () => ({ ok: true, service: "wenxiang" }),
      }),
    });
    const other = await companionIsHealthy("http://127.0.0.1:9/health", {
      fetchImpl: async () => ({
        ok: true,
        json: async () => ({ ok: true, service: "other" }),
      }),
    });
    const down = await companionIsHealthy("http://127.0.0.1:9/health", {
      fetchImpl: async () => {
        throw new Error("connect");
      },
    });
    assert.equal(ok, true);
    assert.equal(other, false);
    assert.equal(down, false);
  });

  it("backs off crashed restarts", () => {
    assert.equal(nextKeepAliveDelay(0, 2000), 2000);
    assert.equal(nextKeepAliveDelay(1, 2000), 4000);
    assert.equal(nextKeepAliveDelay(2, 2000), 8000);
    assert.equal(nextKeepAliveDelay(8, 2000), 30000);
  });
});
