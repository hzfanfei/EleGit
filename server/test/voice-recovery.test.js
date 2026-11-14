import assert from "node:assert/strict";
import { it } from "node:test";
import { createVoiceSession } from "../src/voice-session.js";
import { EventEmitter } from "node:events";
import { createOpenAiAsr } from "../src/voice-openai.js";
import { decodeAdpcm } from "../src/adpcm.js";

const tick = () => new Promise((r) => setImmediate(r));

it("PCM starting with negative samples still uses negotiated ADPCM transport", async () => {
  const packets = [];
  const pcm = Buffer.alloc(1000);
  pcm.set([255, 251, 144, 0]);
  const session = createVoiceSession({
    config: { ready: true }, sendAudio: (bytes) => packets.push(bytes),
    tts: async () => pcm,
    prepareContext: async () => ({ book: {}, materialized: {}, session: {} }),
    ask: async function* () { yield { type: "delta", text: "开始说话。" }; },
  });
  try {
    await session.start({ bookId: "book", audio: "adpcm" });
    session.onTranscript("你好", { final: true });
    await tick();
    assert.equal(packets.length, 1);
    assert.ok(decodeAdpcm(packets[0]));
  } finally { session.hangup(); }
});

it("always streams call audio without requiring a client capability flag", async () => {
  for (const options of [{}, { continuousPcm: false }, { continuousPcm: true }]) {
    const events = [];
    const tts = async () => Buffer.alloc(100);
    tts.stream = async (_text, _signal, send) => {
      await send(Buffer.alloc(100));
      events.push("synth:end");
    };
    const session = createVoiceSession({
      config: { ready: true }, sendAudio: () => events.push("audio"), tts,
      prepareContext: async () => ({ book: {}, materialized: {}, session: {} }),
      ask: async function* () { yield { type: "delta", text: "开始说话。" }; },
    });
    await session.start({ bookId: "book", ...options });
    session.onTranscript("你好", { final: true });
    await tick();
    assert.deepEqual(events, ["audio", "synth:end"]);
    session.hangup();
  }
});

it("quiet speech with a 40ms echo-canceller hole still interrupts, isolated taps do not", async () => {
  const asked = [];
  const session = createVoiceSession({
    config: { ready: true }, sendAudio() {}, asr: { start: async () => {}, push() {} },
    prepareContext: async () => ({ book: {}, materialized: {}, session: {} }),
    ask: async function* (opts) { asked.push(opts.question); yield { type: "delta", text: "这一章介绍勇气的含义。" }; },
    tts: async () => Buffer.alloc(48000),
  });
  await session.start({ bookId: "book" });
  session.onTranscript("请介绍一下", { final: true });
  await tick();
  const frame = (level) => {
    const pcm = Buffer.alloc(640);
    for (let i = 0; i < pcm.length; i += 2) pcm.writeInt16LE(level, i);
    return pcm;
  };
  for (let i = 0; i < 55; i++) session.onPcm(frame(20));
  for (let i = 0; i < 7; i++) session.onPcm(frame(250));
  session.onPcm(frame(0)); session.onPcm(frame(0));
  for (let i = 0; i < 7; i++) session.onPcm(frame(250));
  assert.equal(session.state, "listening");
  session.onTranscript("等等", { final: true });
  await tick();
  assert.deepEqual(asked, ["请介绍一下", "等等"]);
  session.hangup();
});

it("reports OpenAI recognition disconnects without treating intentional stop as failure", async () => {
  const errors = [];
  const sockets = [];
  const asr = createOpenAiAsr({ openai: {}, onError: (err) => errors.push(err), connect: () => {
    const ws = new EventEmitter();
    ws.readyState = 1; ws.send = () => {}; ws.close = () => ws.emit("close");
    sockets.push(ws);
    queueMicrotask(() => ws.emit("open"));
    return ws;
  } });
  await asr.start();
  sockets[0].emit("close");
  sockets[0].emit("error", new Error("closed"));
  assert.equal(errors.length, 1);
  asr.stop();
  await asr.start();
  sockets[0].emit("close");
  asr.stop();
  assert.equal(errors.length, 1);
});

it("ends a broken recognition session if restarting fails", async () => {
  const messages = [];
  let starts = 0;
  const session = createVoiceSession({
    config: { ready: true }, send: (msg) => messages.push(msg),
    asr: { start: async () => { if (++starts > 1) throw new Error("offline"); }, stop() {} },
  });
  await session.start({ bookId: "book" });
  session.onAsrFailure("connection closed");
  session.onAsrFailure("duplicate close");
  await tick();
  assert.equal(starts, 2);
  assert.equal(session.started, false);
  assert.equal(session.state, "idle");
  assert.ok(messages.some((m) => m.type === "error" && m.code === "channel"));
  session.hangup();
});

it("restores call history into the next book question after reconnect", async () => {
  let received;
  const session = createVoiceSession({
    config: { ready: true },
    prepareContext: async () => ({ book: {}, materialized: {}, session: {} }),
    ask: async function* (opts) { received = opts.history; yield { type: "delta", text: "继续讨论。" }; },
    tts: async () => Buffer.alloc(100),
  });
  const history = [{ role: "user", content: "我读到第三章" }, { role: "assistant", content: "这一章讲勇气" }];
  await session.start({ bookId: "book", history });
  session.onTranscript("接着刚才说", { final: true });
  await tick();
  assert.deepEqual(received, history);
  session.hangup();
});

it("accepts a short stop command while thinking with real microphone speech", async () => {
  const questions = [];
  const session = createVoiceSession({
    config: { ready: true },
    prepareContext: async () => ({ book: {}, materialized: {}, session: {} }),
    ask: async function* (opts, signal) {
      questions.push(opts.question);
      await new Promise((resolve) => signal.addEventListener("abort", resolve, { once: true }));
    },
  });
  await session.start({ bookId: "book" });
  session.onTranscript("介绍这本书", { final: true });
  await tick();
  const pcm = Buffer.alloc(12800);
  for (let i = 0; i < pcm.length; i += 2) pcm.writeInt16LE(3000, i);
  session.onPcm(pcm);
  session.onTranscript("等等", { final: true });
  await tick();
  assert.deepEqual(questions, ["介绍这本书", "等等"]);
  session.hangup();
});
