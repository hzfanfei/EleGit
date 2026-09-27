import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { notificationKeyFromRequest } from "../src/notifications.js";

describe("notification upgrade key", () => {
  it("reads the key the phone puts on the query string", () => {
    assert.equal(
      notificationKeyFromRequest({ url: "/v1/notifications?key=from-query", headers: {} }),
      "from-query",
    );
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
