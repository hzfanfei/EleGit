import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  createXiaomiAsr,
  pcm16FromWav,
  pcm16ToWav,
  xiaomiAsrTranscribe,
  xiaomiTts,
} from "../src/xiaomi-speech.js";

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async text() {
      return JSON.stringify(body);
    },
  };
}

describe("xiaomi speech", () => {
  it("turns a wav reply into 24 kHz pcm and sends the preset voice name", async () => {
    const pcm = Buffer.alloc(480, 1);
    const wav = pcm16ToWav(pcm, 24000);
    let seen = null;
    const out = await xiaomiTts(
      { apiKey: "tp-test", ttsVoice: "bingtang", baseUrl: "https://example.test/v1/chat/completions" },
      "你好。",
      undefined,
      async (url, init) => {
        seen = { url, init, body: JSON.parse(init.body) };
        return jsonResponse({
          choices: [{ message: { audio: { data: wav.toString("base64") } } }],
        });
      },
    );
    assert.equal(seen.url, "https://example.test/v1/chat/completions");
    assert.equal(seen.init.headers.Authorization, "Bearer tp-test");
    assert.equal(seen.init.headers["api-key"], "tp-test");
    assert.equal(seen.body.model, "mimo-v2.5-tts");
    assert.equal(seen.body.audio.voice, "冰糖");
    assert.equal(seen.body.audio.format, "wav");
    assert.equal(seen.body.messages[1].content, "你好。");
    assert.equal(out.length, pcm.length);
  });

  it("reads back the pcm payload from a wav", () => {
    const pcm = Buffer.from([1, 2, 3, 4]);
    const parsed = pcm16FromWav(pcm16ToWav(pcm, 16000));
    assert.equal(parsed.sampleRate, 16000);
    assert.deepEqual(parsed.pcm, pcm);
  });

  it("sends buffered microphone pcm as wav and returns the transcript", async () => {
    let model = "";
    const asr = createXiaomiAsr({
      xiaomi: { apiKey: "tp-test", asrModel: "mimo-v2.5-asr" },
      pushToTalk: true,
      onFinal: (text) => {
        model = text;
      },
      fetchImpl: async (_url, init) => {
        const body = JSON.parse(init.body);
        assert.equal(body.model, "mimo-v2.5-asr");
        assert.match(body.messages[0].content[0].input_audio.data, /^data:audio\/wav;base64,/);
        assert.equal(init.headers.Authorization.includes("tp-test"), true);
        return jsonResponse({ choices: [{ message: { content: "你好。" } }] });
      },
    });
    await asr.start();
    asr.push(Buffer.alloc(3200, 2));
    await asr.finalize();
    assert.equal(model, "你好。");
  });

  it("transcribe of empty audio does not call the network", async () => {
    let called = false;
    const text = await xiaomiAsrTranscribe(
      { apiKey: "tp-test" },
      Buffer.alloc(0),
      {
        fetchImpl: async () => {
          called = true;
          return jsonResponse({});
        },
      },
    );
    assert.equal(text, "");
    assert.equal(called, false);
  });
});
