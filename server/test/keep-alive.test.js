import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  COMPANION_ALREADY_RUNNING,
  companionIsHealthy,
  isCompanionAlreadyRunning,
  networkLikelyUp,
  nextKeepAliveDelay,
  shouldRestartCompanion,
  shouldRestartStaleTunnel,
} from "../src/keep-alive-policy.js";

describe("keep-alive policy", () => {
  it("restarts after a clean exit so the supervisor stays up", () => {
    assert.equal(shouldRestartCompanion(0, null), true);
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

  it("restarts stale tunnels only when local is up, public is down, and network is up", () => {
    assert.equal(
      shouldRestartStaleTunnel({
        localHealthy: true,
        publicHealthy: false,
        failStreak: 3,
        threshold: 3,
        networkUp: true,
      }),
      true,
    );
    assert.equal(
      shouldRestartStaleTunnel({
        localHealthy: true,
        publicHealthy: false,
        failStreak: 3,
        threshold: 3,
        networkUp: false,
      }),
      false,
    );
    assert.equal(
      shouldRestartStaleTunnel({
        localHealthy: true,
        publicHealthy: true,
        failStreak: 9,
        threshold: 3,
        networkUp: true,
      }),
      false,
    );
  });

  it("detects outbound network with a lightweight probe", async () => {
    const up = await networkLikelyUp({
      fetchImpl: async () => ({ ok: true, status: 204 }),
    });
    const down = await networkLikelyUp({
      fetchImpl: async () => {
        throw new Error("offline");
      },
    });
    assert.equal(up, true);
    assert.equal(down, false);
  });
});
