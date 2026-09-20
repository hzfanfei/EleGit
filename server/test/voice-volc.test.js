import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { gzipSync } from "node:zlib";
import {
  decodeVolcServerFrame,
  encodeVolcAudio,
  encodeVolcClientRequest,
  extractAsrText,
  volcAsrHeaders,
  volcHeader,
  volcTts,
  volcTtsV3,
  volcTtsV3StreamLatency,
} from "../src/voice-volc.js";

describe("volc binary frames", () => {
  it("encodes a gzip JSON full client request", () => {
    const frame = encodeVolcClientRequest({ user: { uid: "wenxiang" } });
    assert.equal(frame[0], 0x11);
    assert.equal(frame[1], 0x10);
    assert.equal(frame[2], 0x11);
    const decoded = decodeVolcServerFrame(
      Buffer.concat([
        volcHeader({ type: 9, flags: 1, serialization: 1, compression: 1 }),
        Buffer.from([0, 0, 0, 1]),
        (() => {
          const payload = gzipSync(Buffer.from(JSON.stringify({ result: { text: "你好", utterances: [{ text: "你好", definite: true }] } })));
          const size = Buffer.alloc(4);
          size.writeUInt32BE(payload.length);
          return Buffer.concat([size, payload]);
        })(),
      ]),
    );
    assert.equal(decoded.type, "result");
    assert.equal(extractAsrText(decoded.json).text, "你好");
    assert.equal(extractAsrText(decoded.json).definite, true);
    assert.ok(encodeVolcAudio(Buffer.alloc(8)).length > 8);
  });

  it("puts app id and token on ASR headers, never a placeholder secret", () => {
    const headers = volcAsrHeaders({
      appId: "app-1",
      accessToken: "tok-1",
      asrResourceId: "volc.bigasr.sauc.duration",
    });
    assert.equal(headers["X-Api-App-Key"], "app-1");
    assert.equal(headers["X-Api-Access-Key"], "tok-1");
    assert.equal(headers["X-Api-Resource-Id"], "volc.bigasr.sauc.duration");
  });
});

describe("volc TTS", () => {
  it("posts text and returns decoded PCM", async () => {
    const pcm = Buffer.from("abcd");
    const audio = await volcTts(
      {
        appId: "app-1",
        accessToken: "tok-1",
        ttsUrl: "https://openspeech.bytedance.com/api/v1/tts",
        ttsCluster: "volcano_tts",
        ttsVoice: "zh_female_vv_uranus_bigtts",
      },
      "你好。",
      undefined,
      async (url, opts) => {
        assert.equal(url, "https://openspeech.bytedance.com/api/v1/tts");
        const body = JSON.parse(opts.body);
        assert.equal(body.app.appid, "app-1");
        assert.equal(body.request.text, "你好。");
        assert.equal(body.audio.encoding, "pcm");
        return {
          ok: true,
          json: async () => ({ data: pcm.toString("base64") }),
        };
      },
    );
    assert.deepEqual(audio, pcm);
  });

  it("skips unreadable text and does not throw No readable text from v3", async () => {
    const empty = await volcTtsV3(
      { ttsResourceId: "seed-tts-2.0", ttsVoice: "zh_female_vv_uranus_bigtts" },
      "……",
      undefined,
      async () => {
        throw new Error("should not call TTS for punctuation-only text");
      },
    );
    assert.equal(empty.length, 0);

    const audio = await volcTtsV3(
      { ttsResourceId: "seed-tts-2.0", ttsVoice: "zh_female_vv_uranus_bigtts" },
      "你好。",
      undefined,
      async () => ({
        ok: true,
        body: {
          async *[Symbol.asyncIterator]() {
            yield Buffer.from(JSON.stringify({ code: 3001, message: "No readable text" }));
          },
        },
      }),
    );
    assert.equal(audio.length, 0);
  });

  it("reports TTFT on v3 stream chunks", async () => {
    const pcm = Buffer.from("abcd");
    const report = await volcTtsV3StreamLatency(
      { ttsResourceId: "seed-tts-2.0", ttsVoice: "zh_female_vv_uranus_bigtts" },
      "你好。",
      undefined,
      async () => ({
        ok: true,
        body: {
          async *[Symbol.asyncIterator]() {
            yield Buffer.from(JSON.stringify({ code: 0, data: pcm.toString("base64") }));
          },
        },
      }),
    );
    assert.equal(report.ok, true);
    assert.equal(report.pcmBytes, 4);
    assert.equal(report.streamChunks, 1);
    assert.ok(report.ttftMs >= 0);
    assert.ok(report.totalMs >= report.ttftMs);
  });
});
