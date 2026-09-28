import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  RESTART_NOTICE_KIND,
  restartNoticePayload,
} from "../src/restart-notice.js";

describe("restart notice", () => {
  it("builds inbox payload with optional lead time", () => {
    const payload = restartNoticePayload({
      reason: "改了 server",
      source: "Agent",
      delayMs: 1500,
    });
    assert.equal(payload.kind, RESTART_NOTICE_KIND);
    assert.equal(payload.title, "问象即将重启");
    assert.match(payload.body, /Agent/);
    assert.match(payload.body, /2 秒后生效/);
  });
});
