import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { notificationKeyFromRequest, shouldPushNotice } from "../src/notifications.js";

describe("notification upgrade key", () => {
  it("reads the key the phone puts on the query string", () => {
    assert.equal(
      notificationKeyFromRequest({ url: "/v1/notifications?key=from-query", headers: {} }),
      "from-query",
    );
  });

  it("pushes a finished turn once and keeps progress off the alert", () => {
    assert.equal(shouldPushNotice({ partial: true }, { partial: true, alert: false }), true);
    assert.equal(shouldPushNotice({ partial: true }, { partial: false, alert: false }), false);
    assert.equal(shouldPushNotice({}, { partial: false, alert: true }), true);
    assert.equal(shouldPushNotice({}, { partial: false, alert: false }), false);
  });

  it("prefers the header when both are present", () => {
    assert.equal(
      notificationKeyFromRequest({
        url: "/v1/notifications?key=from-query",
        headers: { "x-wenxiang-key": "from-header" },
      }),
      "from-header",
    );
  });
});
