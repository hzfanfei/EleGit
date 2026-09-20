import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createFunasrAsr } from "../src/funasr-asr.js";

describe("createFunasrAsr", () => {
  it("push-to-talk keeps buffering until finalize (no mid-hold final)", async () => {
    let posts = 0;
    const asr = createFunasrAsr({
      funasr: { baseUrl: "http://127.0.0.1:9" },
      pushToTalk: true,
      onFinal: () => {
        posts += 1;
      },
      fetchImpl: async () => ({ ok: true, json: async () => ({ text: "x", final: false }) }),
    });
    await asr.start();
    asr.push(Buffer.alloc(32000 + 100, 1));
    await new Promise((r) => setTimeout(r, 1400));
    assert.equal(posts, 0);
    await asr.finalize();
    assert.equal(posts, 1);
  });

  it("finalize POSTs PCM and emits final transcript", async () => {
    const pcm = Buffer.alloc(32000, 0);
    const calls = [];
    const asr = createFunasrAsr({
      funasr: { baseUrl: "http://127.0.0.1:9" },
      onFinal: (text) => calls.push({ type: "final", text }),
      fetchImpl: async (url, opts) => {
        assert.equal(url, "http://127.0.0.1:9/v1/asr");
        assert.equal(opts.headers["X-Final"], "1");
        assert.ok(Buffer.isBuffer(opts.body));
        return { ok: true, json: async () => ({ text: "你好", final: true }) };
      },
    });
    await asr.start();
    asr.push(pcm);
    await asr.finalize();
    assert.deepEqual(calls, [{ type: "final", text: "你好" }]);
  });
});
