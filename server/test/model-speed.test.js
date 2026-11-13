import { test } from "node:test";
import assert from "node:assert/strict";
import { measureModelSpeed } from "../src/model-speed.js";

function fake(usage) {
  return class {
    static closed = false;
    async start() {}
    async prompt(text, { onDelta }) {
      onDelta("one ");
      await new Promise(r => setTimeout(r, 20));
      onDelta("two");
      return { usage };
    }
    async close() { this.constructor.closed = true; }
  };
}
test("reports provider output usage and closes the isolated channel", async () => {
  const Channel = fake({ outputTokens: 10 });
  const r = await measureModelSpeed("book", { command: { model: "test" }, Channel });
  assert.equal(r.outputTokens, 10);
  assert.ok(r.tokensPerSecond > 0);
  assert.equal(Channel.closed, true);
});
test("does not substitute characters for missing token usage", async () => {
  const r = await measureModelSpeed("repo", { command: { model: "test" }, Channel: fake(null) });
  assert.equal(r.tokensPerSecond, null);
  assert.equal(r.outputTokens, null);
});
