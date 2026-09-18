import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { nextKeepAliveDelay, shouldRestartCompanion } from "../src/keep-alive-policy.js";

describe("keep-alive policy", () => {
  it("does not restart a clean exit", () => {
    assert.equal(shouldRestartCompanion(0, null), false);
    assert.equal(shouldRestartCompanion(1, null), true);
    assert.equal(shouldRestartCompanion(null, "SIGTERM"), true);
  });

  it("backs off crashed restarts", () => {
    assert.equal(nextKeepAliveDelay(0, 2000), 2000);
    assert.equal(nextKeepAliveDelay(1, 2000), 4000);
    assert.equal(nextKeepAliveDelay(2, 2000), 8000);
    assert.equal(nextKeepAliveDelay(8, 2000), 30000);
  });
});
