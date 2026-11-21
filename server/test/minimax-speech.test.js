import assert from "node:assert/strict";
import { once } from "node:events";
import { Readable } from "node:stream";
import { describe, it } from "node:test";
import {
  createMinimaxAsr,
  minimaxAsrTranscribe,
  minimaxTtsStream,
} from "../src/minimax-speech.js";

function scriptedSocket({ finish = true } = {}) {
  const listeners = { message: [], close: [], error: [] };
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
          if (finish) deliver({ event: "task_flushed" });
          else socket.close();
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
  it("cancels a stalled connection before synthesis starts", async () => {
    const controller = new AbortController();
    const task = minimaxTtsStream({}, "Hello world.", {
      signal: controller.signal, connectImpl: () => new Promise(() => {}),
    });
    controller.abort();
    await assert.rejects(task, { code: "cancelled" });
  });

  it("times out the connection and closes a socket that arrives late", async () => {
    let complete;
    let closed = false;
    const task = minimaxTtsStream({}, "Hello world.", {
      timeoutMs: 20, connectImpl: () => new Promise((resolve) => { complete = resolve; }),
    });
    await assert.rejects(task, /connect timeout/);
    complete({ close() { closed = true; } });
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(closed, true);
  });
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

  it("reports a synthesis disconnect after emitting audio but before completion", async () => {
    const socket = scriptedSocket({ finish: false });
    const parts = [];
    await assert.rejects(
      minimaxTtsStream({}, "你好。", { connectImpl: () => socket, onPcm: (pcm) => parts.push(pcm) }),
      /connection closed before synthesis finished/,
    );
    assert.deepEqual(Buffer.concat(parts), Buffer.from([1, 2, 3, 4]));
    assert.equal(socket.sent.some((msg) => msg.event === "task_finish"), false);
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

  it("times out a stalled recognition stream and processes the next utterance", { timeout: 3000 }, async () => {
    const errors = [];
    let requests = 0;
    let firstSignal;
    let resolvePartial;
    let resolveFinal;
    const firstPartial = new Promise((resolve) => { resolvePartial = resolve; });
    const final = new Promise((resolve) => { resolveFinal = resolve; });
    const asr = createMinimaxAsr({
      minimax: {},
      endpointSilenceMs: 5,
      requestTimeoutMs: 100,
      onPartial: (text) => { if (text === "上句") resolvePartial(); },
      onFinal: resolveFinal,
      onError: (err) => errors.push(err.message),
      fetchImpl: async (_url, { signal }) => {
        if (++requests === 1) {
          firstSignal = signal;
          return { ok: true, body: Readable.from((async function* () {
            yield Buffer.from('data: {"delta":"上句","finish":false}\n');
            if (!signal.aborted) await once(signal, "abort");
            throw signal.reason;
          })()) };
        }
        return new Response('data: {"delta":"下句","finish":true}\n');
      },
    });
    const speak = () => {
      asr.push(Buffer.alloc(19200, 8));
      asr.push(Buffer.alloc(640));
    };
    try {
      await asr.start();
      speak();
      await firstPartial;
      speak();
      assert.equal(await final, "下句");
      assert.equal(requests, 2);
      assert.equal(firstSignal.aborted, true);
      assert.deepEqual(errors, ["minimax asr timeout"]);
    } finally {
      asr.stop();
    }
  });

  it("cancels discarded recognition without reporting an error for that utterance", { timeout: 3000 }, async () => {
    let resolveOpened;
    const opened = new Promise((resolve) => { resolveOpened = resolve; });
    const results = [];
    const asr = createMinimaxAsr({
      minimax: {},
      pushToTalk: true,
      onFinal: (text) => results.push(text),
      onError: (err) => results.push(err.message),
      fetchImpl: async (_url, { signal }) => {
        resolveOpened(signal);
        await once(signal, "abort");
        throw signal.reason;
      },
    });
    await asr.start();
    asr.push(Buffer.alloc(640));
    const pending = asr.finalize();
    const signal = await opened;
    asr.discard();
    await pending;
    assert.equal(signal.aborted, true);
    assert.deepEqual(results, []);
  });
});
