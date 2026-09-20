import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { cosyvoiceTts } from "../src/cosyvoice-tts.js";

describe("cosyvoiceTts", () => {
  it("POSTs text and returns PCM buffer", async () => {
    const pcm = Buffer.from("abcd");
    const out = await cosyvoiceTts(
      { baseUrl: "http://127.0.0.1:9", ttsVoice: "zh_xiaoxiao" },
      "你好",
      undefined,
      async (url, opts) => {
        assert.equal(url, "http://127.0.0.1:9/v1/tts");
        const body = JSON.parse(opts.body);
        assert.equal(body.text, "你好");
        assert.equal(body.spk_id, "zh_xiaoxiao");
        return {
          ok: true,
          arrayBuffer: async () => {
            const ab = new ArrayBuffer(pcm.length);
            new Uint8Array(ab).set(pcm);
            return ab;
          },
        };
      },
    );
    assert.deepEqual(out, pcm);
  });
});
