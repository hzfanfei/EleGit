import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { turnRelayEnabled } from "../src/turn-relay-client.js";

describe("turnRelayEnabled", () => {
  it("is on by default", () => {
    assert.equal(turnRelayEnabled({}), true);
    assert.equal(turnRelayEnabled({ WENXIANG_TURN_RELAY: "" }), true);
  });

  it("respects WENXIANG_TURN_RELAY opt-out", () => {
    assert.equal(turnRelayEnabled({ WENXIANG_TURN_RELAY: "0" }), false);
    assert.equal(turnRelayEnabled({ WENXIANG_TURN_RELAY: "false" }), false);
    assert.equal(turnRelayEnabled({ WENXIANG_TURN_RELAY: "1" }), true);
  });

  it("still honors WENXIANG_DEV_WATCH when relay unset", () => {
    assert.equal(turnRelayEnabled({ WENXIANG_DEV_WATCH: "1" }), true);
  });
});
