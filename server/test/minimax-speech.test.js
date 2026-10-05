import assert from "node:assert/strict";
import { Readable } from "node:stream";
import { describe, it } from "node:test";
import {
  createMinimaxAsr,
  minimaxAsrTranscribe,
  minimaxTtsStream,
} from "../src/minimax-speech.js";

function scriptedSocket() {
  const listeners = { message: [], close: [] };
  const sent = [];
  let announced = false;
  const socket = {
    sent,
    on(event, fn) {
      listeners[event].push(fn);
      if (event === "message" && !announced) {
        announced = true;
        queueMicrotask(() => deliver({ event: "connected_success" }));
      }
    },
    off(event, fn) {
      listeners[event] = (listeners[event] || []).filter((item) => item !== fn);
    },
    send(raw) {
      const msg = JSON.parse(raw);
      sent.push(msg);
      if (msg.event === "task_start") queueMicrotask(() => deliver({ event: "task_started" }));
      if (msg.event === "task_flush") {
        queueMicrotask(() => {
          deliver({ event: "task_continued", data: { audio: "0102" } });
          deliver({ event: "task_continued", data: { audio: "0304" } });
          deliver({ event: "task_flushed" });
        });
      }
    },
    close() {
      for (const fn of [...(listeners.close || [])]) fn();
    },
  };
  function deliver(msg) {
    for (const fn of [...(listeners.message || [])]) fn(JSON.stringify(msg));
  }
  return socket;
}

describe("minimax speech", () => {
  it("streams one sentence over the bidirectional websocket and returns pcm", async () => {
    const socket = scriptedSocket();
    const parts = [];
    const total = await minimaxTtsStream(
      {
        apiKey: "sk-test",
        ttsUrl: "wss://api.minimax.cn/ws/v1/t2a_v2_bidi",
        ttsModel: "speech-2.8-turbo",
        ttsVoice: "female-shaonv",
      },
      "你好。",
      {
        connectImpl: () => socket,
        onPcm: async (pcm) => {
          parts.push(Buffer.from(pcm));
        },
      },
    );
    assert.equal(socket.sent[0].event, "task_start");
    assert.equal(socket.sent[0].model, "speech-2.8-turbo");
    assert.equal(socket.sent[0].voice_setting.voice_id, "female-shaonv");
    assert.equal(socket.sent[0].audio_setting.format, "pcm");
    assert.equal(socket.sent[0].audio_setting.sample_rate, 24000);
    assert.deepEqual(
      socket.sent.map((msg) => msg.event),
      ["task_start", "task_continue", "task_flush", "task_finish"],
    );
    assert.equal(socket.sent[1].text, "你好。");
    assert.equal(total, 4);
    assert.deepEqual(Buffer.concat(parts), Buffer.from([1, 2, 3, 4]));
  });

  it("uploads one wav and concatenates streamed asr deltas", async () => {
    const partials = [];
    const text = await minimaxAsrTranscribe(
      { apiKey: "sk-test", asrUrl: "https://api.minimax.cn/v1/speech_to_text", asrModel: "asr-1.0" },
      Buffer.alloc(3200, 1),
      {
        onDelta: (_delta, soFar) => partials.push(soFar),
        fetchImpl: async (url, init) => {
          assert.equal(url, "https://api.minimax.cn/v1/speech_to_text");
          assert.equal(init.headers.Authorization, "Bearer sk-test");
          assert.equal(init.headers.language, "zh");
          assert.equal(init.body.get("model"), "asr-1.0");
          assert.equal(init.body.get("stream"), "true");
          assert.equal(init.body.get("file").type, "audio/wav");
          return {
            ok: true,
            status: 200,
            body: Readable.from([
              Buffer.from('data: {"index":0,"delta":"你","finish":false}\n\n'),
              Buffer.from('data: {"index":1,"delta":"好","finish":false}\n\n'),
              Buffer.from('data: {"index":2,"delta":"","finish":true,"duration":1.2}\n\n'),
            ]),
          };
        },
      },
    );
    assert.deepEqual(partials, ["你", "你好", "你好"]);
    assert.equal(text, "你好");
  });

  it("recognizes a finished push-to-talk clip", async () => {
    let finalText = "";
    const partials = [];
    const asr = createMinimaxAsr({
      minimax: { apiKey: "sk-test", asrUrl: "https://api.minimax.cn/v1/speech_to_text" },
      pushToTalk: true,
      onPartial: (text) => partials.push(text),
      onFinal: (text) => {
        finalText = text;
      },
      fetchImpl: async () => ({
        ok: true,
        status: 200,
        body: Readable.from([Buffer.from('data: {"index":0,"delta":"在听","finish":true}\n\n')]),
      }),
    });
    await asr.start();
    asr.push(Buffer.alloc(3200, 2));
    await asr.finalize();
    assert.deepEqual(partials, ["在听"]);
    assert.equal(finalText, "在听");
  });
});
