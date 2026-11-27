import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { it } from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { configureServerLogs, listErrorLogs } from "../src/server-logs.js";
import { createVoiceSession } from "../src/voice-session.js";
import { EventEmitter } from "node:events";
import { createOpenAiAsr } from "../src/voice-openai.js";
import { decodeAdpcm } from "../src/adpcm.js";
import { createMinimaxAsr } from "../src/minimax-speech.js";

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

it("logs a book reply stopped by microphone level before a transcript arrives", { timeout: 3000 }, async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "wx-voice-interrupt-"));
  configureServerLogs(root);
  const states = [];
  const session = createVoiceSession({
    config: { ready: true },
    send: (event) => { if (event.type === "state") states.push(event); },
    sendAudio() {},
    asr: { async start() {}, push() {} },
    prepareContext: async () => ({ book: {}, materialized: {} }),
    ask: async function* () { yield { type: "done", answer: "这一章介绍勇气的含义。" }; },
    tts: async () => Buffer.alloc(48000),
  });
  t.after(async () => {
    session.hangup();
    configureServerLogs("");
    await rm(root, { recursive: true, force: true });
  });
  await session.start({ bookId: "book" });
  session.onTranscript("请介绍一下", { final: true });
  await tick();
  const quiet = Buffer.alloc(640);
  for (let i = 0; i < 50; i++) session.onPcm(quiet);
  assert.equal(session.state, "speaking");
  assert.deepEqual(await listErrorLogs(root), []);

  const echo = Buffer.alloc(640);
  for (let i = 0; i < echo.length; i += 2) echo.writeInt16LE(250, i);
  for (let i = 0; i < 13; i++) session.onPcm(echo);
  assert.deepEqual(states.slice(-2), [
    { type: "state", state: "barge", reason: "speech" },
    { type: "state", state: "listening" },
  ]);
  let rows = await listErrorLogs(root);
  while (!rows.length) {
    await delay(10, undefined, { signal: t.signal });
    rows = await listErrorLogs(root);
  }
  assert.equal(rows.length, 1);
  assert.equal(rows[0].kind, "voice-turn");
  assert.equal(rows[0].summary, "问书电话提前停播 · 麦克风音量触发");
  assert.match(rows[0].message, /触发时尚未确认有人说话.*RMS 250，门槛 100，超阈值音频约 260 毫秒/);
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

it("a failed MiniMax utterance leaves the recognition queue running", async () => {
  const messages = [];
  let starts = 0;
  let stops = 0;
  const session = createVoiceSession({
    config: { ready: true },
    send: (msg) => messages.push(msg),
    asr: { async start() { starts++; }, stop() { stops++; } },
  });
  try {
    await session.start({ bookId: "book" });
    session.onAsrFailure("minimax asr timeout", { utteranceOnly: true });
    await tick();
    assert.equal(starts, 1);
    assert.equal(stops, 0);
    assert.equal(session.state, "listening");
    assert.ok(messages.some((m) => m.type === "caption" && m.code === "turn_notice"));
  } finally {
    session.hangup();
  }
});

it("a partial TTS failure sends a retry notice instead of a completed answer", async () => {
  const messages = [];
  const audio = [];
  const tts = async () => assert.fail("must not replay a sentence with a delivered prefix");
  tts.stream = async (_text, _signal, send) => {
    await send(Buffer.alloc(9600));
    throw new Error("minimax tts connection closed before synthesis finished");
  };
  const session = createVoiceSession({
    config: { ready: true }, send: (msg) => messages.push(msg), sendAudio: (pcm) => audio.push(pcm),
    prepareContext: async () => ({ book: {}, materialized: {} }),
    ask: async function* () { yield { type: "done", answer: "这是应当完整朗读的回答。" }; },
    tts,
  });
  try {
    await session.start({ bookId: "book" });
    session.onTranscript("讲讲这一章", { final: true });
    await tick();
    assert.equal(audio.length, 1);
    const final = messages.filter((m) => m.role === "assistant" && m.final);
    assert.equal(final.length, 1);
    assert.equal(final[0].code, "turn_notice");
    assert.ok(messages.some((m) => m.state === "audio_done"));
    session.playbackDone();
    assert.equal(session.state, "listening");
  } finally {
    session.hangup();
  }
});

it("keeps the start of a follow-up crossing the end of playback", { timeout: 3000 }, async () => {
  const asked = [];
  const messages = [];
  let recognized;
  const followup = new Promise((resolve) => { recognized = resolve; });
  const asr = createMinimaxAsr({
    minimax: {},
    endpointSilenceMs: 520,
    minEndpointBytes: 17600,
    fetchImpl: async () => new Response('data: {"delta":"主人公后来去哪儿","finish":true}\n'),
    onFinal: (text) => session.onTranscript(text, { final: true }),
  });
  const session = createVoiceSession({
    config: { ready: true }, send: (msg) => messages.push(msg), sendAudio() {}, asr,
    prepareContext: async () => ({ book: {}, materialized: {} }),
    ask: async function* (opts) {
      asked.push(opts.question);
      if (asked.length === 2) recognized();
      yield { type: "done", answer: "这一章介绍人物如何面对变化。" };
    },
    tts: async () => Buffer.alloc(48000),
  });
  const voice = Buffer.alloc(640);
  for (let i = 0; i < voice.length; i += 2) voice.writeInt16LE(1600, i);
  const silence = Buffer.alloc(640);
  try {
    await session.start({ bookId: "book" });
    session.onTranscript("讲讲这一章", { final: true });
    await tick();
    assert.ok(messages.some((m) => m.state === "audio_done"));
    for (let i = 0; i < 12; i++) session.onPcm(voice);
    assert.equal(session.state, "speaking");
    session.playbackDone();
    for (let i = 0; i < 9; i++) session.onPcm(voice);
    for (let i = 0; i < 26; i++) session.onPcm(silence);
    await followup;
    assert.deepEqual(asked, ["讲讲这一章", "主人公后来去哪儿"]);
  } finally {
    session.hangup();
  }
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
