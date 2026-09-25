import assert from "node:assert/strict";
import { createServer } from "node:http";
import { describe, it } from "node:test";
import { bindCompanion } from "../src/listen.js";

describe("bindCompanion", () => {
  it("reports busy when the port is already taken", async () => {
    const first = createServer();
    const bound = await bindCompanion(first, 0, "127.0.0.1");
    assert.equal(bound, "bound");
    const port = first.address().port;
    const second = createServer();
    try {
      assert.equal(await bindCompanion(second, port, "127.0.0.1"), "busy");
    } finally {
      await new Promise((resolve) => first.close(resolve));
      second.close();
    }
  });
});
