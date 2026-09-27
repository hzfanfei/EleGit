import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createVoiceSession } from "../src/voice-session.js";

function loudPcm() {
  const buf = Buffer.alloc(640);
  for (let i = 0; i < buf.length; i += 2) buf.writeInt16LE(14000, i);
  return buf;
}

function speechBurst() {
  const buf = Buffer.alloc(16000 * 2 * 0.4);
  for (let i = 0; i < buf.length; i += 2) buf.writeInt16LE(14000, i);
  return buf;
}

describe("createVoiceSession", () => {
  it("refuses to start a fake demo when keys are missing", async () => {
    const sent = [];
    const session = createVoiceSession({
      config: { ready: false, hint: "还没配语音密钥" },
      send: (msg) => sent.push(msg),
    });
    await session.start({ owner: "octo", repo: "demo" });
    assert.equal(sent[0].type, "error");
    assert.equal(sent[0].code, "unconfigured");
    assert.equal(sent[0].hint, "还没配语音密钥");
    assert.equal(session.started, false);
  });

  it("runs Agent text through TTS and barges in while speaking", async () => {
    const sent = [];
    const audio = [];
    let cancelled = 0;
    let ttsCalls = 0;
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: (msg) => sent.push(msg),
      sendAudio: (buf) => audio.push(Buffer.from(buf)),
      checkout: async () => ({ dest: "/tmp/octo/demo", local: { present: true, path: "/tmp/octo/demo" }, progress: { repo: { fullName: "octo/demo" } } }),
      sessions: {
        resolveForChat: () => ({ id: "s1" }),
        cancel: async () => {
          cancelled += 1;
        },
      },
      ask: async function* (_q, signal) {
        yield { type: "start", engine: "acp" };
        yield { type: "delta", text: "仓库最近在修登录。" };
        await new Promise((r) => setTimeout(r, 40));
        if (signal?.aborted) return;
        yield { type: "delta", text: "后面这句不该再播。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。后面这句不该再播。" };
      },
      tts: async (text, signal) => {
        ttsCalls += 1;
        await new Promise((r) => setTimeout(r, 80));
        if (signal?.aborted) {
          const err = new Error("cancelled");
          err.code = "cancelled";
          throw err;
        }
        return Buffer.from(`pcm:${text}`);
      },
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    assert.equal(sent.some((m) => m.type === "state" && m.state === "listening"), true);

    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(sent.some((m) => m.type === "state" && m.state === "speaking"), true);

    session.onPcm(loudPcm());
    session.onTranscript("先停一下", { final: false });
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(sent.some((m) => m.type === "state" && m.state === "barge"), false);

    session.onPcm(speechBurst());
    session.onTranscript("先停一下", { final: true });
    await new Promise((r) => setTimeout(r, 120));

    assert.equal(sent.some((m) => m.type === "state" && m.state === "barge"), true);
    assert.equal(sent.filter((m) => m.type === "state" && m.state === "listening").length >= 2, true);
    assert.ok(cancelled >= 1);
    assert.ok(ttsCalls >= 1);
    const captions = sent.filter((m) => m.type === "caption");
    assert.equal(captions.some((m) => m.role === "user" && m.text.includes("最近在做什么")), true);
  });

  it("answers the sentence that interrupted the reply", async () => {
    const asked = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "先说到这里。" };
        yield { type: "done", engine: "acp", answer: "先说到这里。" };
      },
      tts: async (_text, signal) => {
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, 400);
          signal?.addEventListener("abort", () => {
            clearTimeout(timer);
            resolve();
          }, { once: true });
        });
        if (signal?.aborted) {
          const err = new Error("cancelled");
          err.code = "cancelled";
          throw err;
        }
        return Buffer.from("pcm");
      },
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(asked[0], "最近在做什么？");
    assert.equal(session.state, "speaking");

    session.onTranscript("换个话题", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.deepEqual(asked, ["最近在做什么？", "换个话题"]);
    assert.equal(session.state, "speaking");
  });

  it("answers the utterance that barged in by speech, even inside the hold", async () => {
    const asked = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "先说到这里。" };
        yield { type: "done", engine: "acp", answer: "先说到这里。" };
      },
      tts: async (_text, signal) => {
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, 400);
          signal?.addEventListener("abort", () => {
            clearTimeout(timer);
            resolve();
          }, { once: true });
        });
        if (signal?.aborted) return Buffer.alloc(0);
        return Buffer.from("pcm");
      },
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(session.state, "speaking");

    session.barge("speech");
    session.onTranscript("换个话题", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.deepEqual(asked, ["最近在做什么？", "换个话题"]);
  });

  it("drops a tap-barge echo that arrives inside the hold", async () => {
    const asked = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "先说到这里。" };
        yield { type: "done", engine: "acp", answer: "先说到这里。" };
      },
      tts: async (_text, signal) => {
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, 400);
          signal?.addEventListener("abort", () => {
            clearTimeout(timer);
            resolve();
          }, { once: true });
        });
        if (signal?.aborted) return Buffer.alloc(0);
        return Buffer.from("pcm");
      },
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(session.state, "speaking");

    session.barge();
    session.onTranscript("喇叭回声", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.deepEqual(asked, ["最近在做什么？"]);
  });

  it("ignores the assistant line leaking back through the mic", async () => {
    const asked = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "仓库最近在修登录。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
      },
      tts: async (_text, signal) => {
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, 400);
          signal?.addEventListener("abort", () => {
            clearTimeout(timer);
            resolve();
          }, { once: true });
        });
        if (signal?.aborted) return Buffer.alloc(0);
        return Buffer.from("pcm");
      },
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 30));
    assert.equal(session.state, "speaking");

    session.onTranscript("仓库最近在修登录", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.deepEqual(asked, ["最近在做什么？"]);
    assert.equal(session.state, "speaking");
  });

  it("asks the open book without checking out a repo", async () => {
    const asked = [];
    let prepared = 0;
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      prepareContext: async ({ bookId, chapter, sessionId }) => {
        prepared += 1;
        assert.equal(bookId, "b1");
        assert.equal(chapter, "第一章");
        assert.equal(sessionId, "book-s1");
        return {
          book: { id: "b1", title: "演示书" },
          materialized: { cacheDir: "/tmp/book" },
          session: { id: "book-s1" },
          sessions: { cancel: async () => {} },
        };
      },
      checkout: async () => {
        throw new Error("book call must not checkout a repo");
      },
      ask: async function* (opts) {
        asked.push(opts);
        yield { type: "delta", text: "墙纸是压抑。" };
        yield { type: "done", engine: "acp", answer: "墙纸是压抑。" };
      },
      tts: async () => Buffer.from("pcm"),
    });

    await session.start({ bookId: "b1", chapter: "第一章", sessionId: "book-s1" });
    assert.equal(session.state, "listening");
    session.onTranscript("墙纸象征什么", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.equal(prepared, 1);
    assert.equal(asked.length, 1);
    assert.equal(asked[0].question, "墙纸象征什么");
    assert.equal(asked[0].book.id, "b1");
    assert.equal(asked[0].chapter, "第一章");
    assert.equal(session.state, "listening");
  });

  it("keeps speaking until the phone finishes playback", async () => {
    const sent = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: (msg) => sent.push(msg),
      sendAudio: () => {},
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* () {
        yield { type: "delta", text: "先说到这里。" };
        yield { type: "done", engine: "acp", answer: "先说到这里。" };
      },
      tts: async () => Buffer.from("pcm"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.equal(session.state, "speaking");
    const states = sent.filter((msg) => msg.type === "state").map((msg) => msg.state);
    assert.equal(states.at(-1), "audio_done");

    session.playbackDone();
    assert.equal(session.state, "listening");
  });

  it("returns to listening if the phone never reports playback", async () => {
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      playbackFallbackMs: 200,
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* () {
        yield { type: "delta", text: "先说到这里。" };
        yield { type: "done", engine: "acp", answer: "先说到这里。" };
      },
      tts: async () => Buffer.from("pcm"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(session.state, "speaking");
    await new Promise((r) => setTimeout(r, 400));
    assert.equal(session.state, "listening");
  });

  it("does not open the mic on the short playback estimate", async () => {
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* () {
        yield { type: "delta", text: "先说到这里。" };
        yield { type: "done", engine: "acp", answer: "先说到这里。" };
      },
      tts: async () => Buffer.from("pcm"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(session.state, "speaking");
    await new Promise((r) => setTimeout(r, 1400));
    assert.equal(session.state, "speaking");
  });

  it("ignores speaker bleed while audio is still going out", async () => {
    const asked = [];
    let discarded = 0;
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: {
        async start() {},
        discard() {
          discarded += 1;
        },
      },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "仓库最近在修登录。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(session.state, "speaking");
    assert.equal(discarded, 2);

    session.barge("speech");
    session.onTranscript("仓库最近", { final: false });
    session.onTranscript("仓库最近在修登入", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.deepEqual(asked, ["最近在做什么？"]);
    assert.equal(session.state, "speaking");

    session.onTranscript("换个话题吧", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["最近在做什么？"]);
    assert.equal(session.state, "speaking");

    session.playbackDone();
    session.onTranscript("换个话题吧", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["最近在做什么？", "换个话题吧"]);
  });

  it("loud speech during playback interrupts and is answered", async () => {
    const asked = [];
    const pushed = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: {
        async start() {},
        push(buf) {
          pushed.push(buf);
        },
      },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "仓库最近在修登录。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(session.state, "speaking");

    session.onPcm(speechBurst());
    assert.equal(pushed.length, 1);
    session.onTranscript("换个话题吧", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["最近在做什么？", "换个话题吧"]);
  });

  it("stays on the call when the open book cannot be loaded", async () => {
    const sent = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: (msg) => sent.push(msg),
      prepareContext: async () => {
        throw new Error("missing book");
      },
      tts: async () => Buffer.alloc(0),
    });

    await session.start({ bookId: "b1", chapter: "第一章", sessionId: "book-s1" });
    session.onTranscript("墙纸象征什么", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.equal(sent.some((msg) => msg.type === "error"), false);
    assert.ok(sent.some((msg) => msg.type === "caption" && msg.text === "没找到这本书"));
    assert.equal(session.started, true);
    assert.equal(session.state, "listening");
  });

  it("stays on the call when the book answer fails", async () => {
    const sent = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: (msg) => sent.push(msg),
      prepareContext: async () => ({
        book: { id: "b1", title: "演示书" },
        materialized: { cacheDir: "/tmp/book" },
        session: { id: "book-s1" },
        sessions: { cancel: async () => {} },
      }),
      ask: async function* () {
        throw new Error("agent down");
      },
      tts: async () => Buffer.alloc(0),
    });

    await session.start({ bookId: "b1", chapter: "第一章", sessionId: "book-s1" });
    session.onTranscript("墙纸象征什么", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.equal(sent.some((msg) => msg.type === "error"), false);
    assert.ok(sent.some((msg) => msg.type === "caption" && msg.text === "这句没说成，再说一次"));
    assert.equal(session.started, true);
    assert.equal(session.state, "listening");
  });

  it("does not feed speaker-level mic audio into recognition while playback is open", async () => {
    const pushed = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: {
        async start() {},
        push(buf) {
          pushed.push(buf);
        },
      },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* () {
        yield { type: "delta", text: "仓库最近在修登录。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(session.state, "speaking");

    const quiet = Buffer.alloc(640);
    for (let i = 0; i < quiet.length; i += 2) quiet.writeInt16LE(200, i);
    session.onPcm(quiet);
    session.onPcm(loudPcm());
    assert.equal(pushed.length, 0);

    session.playbackDone();
    session.onPcm(loudPcm());
    assert.equal(pushed.length, 1);
  });

  it("conversation-level speech during playback interrupts and is answered", async () => {
    const asked = [];
    const pushed = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: {
        async start() {},
        push(buf) {
          pushed.push(buf);
        },
      },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "仓库最近在修登录。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    const speaker = Buffer.alloc(16000 * 2 * 0.4);
    for (let i = 0; i < speaker.length; i += 2) speaker.writeInt16LE(500, i);
    session.onPcm(speaker);
    assert.equal(pushed.length, 0);
    assert.equal(session.state, "speaking");

    const voice = Buffer.alloc(16000 * 2 * 0.3);
    for (let i = 0; i < voice.length; i += 2) voice.writeInt16LE(2500, i);
    session.onPcm(voice);
    assert.equal(pushed.length, 1);
    session.onTranscript("换个话题吧", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["最近在做什么？", "换个话题吧"]);
  });

  it("a voice squeezed by echo cancel still interrupts once the speaker is known to be quiet", async () => {
    const asked = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: { async start() {}, push() {} },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "仓库最近在修登录。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    const frame = (level) => {
      const buf = Buffer.alloc(2560);
      for (let i = 0; i < buf.length; i += 2) buf.writeInt16LE(i % 4 ? -level : level, i);
      return buf;
    };
    for (let i = 0; i < 15; i += 1) session.onPcm(frame(i % 3 ? 0 : 40));
    assert.equal(session.state, "speaking");
    for (let i = 0; i < 4; i += 1) session.onPcm(frame(250));
    assert.equal(session.state, "listening");
    session.onTranscript("换个话题吧", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["最近在做什么？", "换个话题吧"]);
  });

  it("lifts a squeezed interruption over a gated recognizer's speech floor", async () => {
    const { pcmRms } = await import("../src/voice-call.js");
    for (const floor of [420, undefined]) {
      const pushed = [];
      const session = createVoiceSession({
        config: { ready: true, provider: "xiaomi" },
        send: () => {},
        sendAudio: () => {},
        asr: {
          speechFloorRms: floor,
          async start() {},
          push(buf) {
            pushed.push(buf);
          },
        },
        checkout: async () => ({ dest: "/tmp/octo/demo" }),
        sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
        ask: async function* () {
          yield { type: "delta", text: "仓库最近在修登录。" };
          yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
        },
        tts: async () => Buffer.from("pcm-audio-bytes"),
      });

      await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
      session.onTranscript("最近在做什么？", { final: true });
      await new Promise((r) => setTimeout(r, 40));

      const frame = (level) => {
        const buf = Buffer.alloc(2560);
        for (let i = 0; i < buf.length; i += 2) buf.writeInt16LE(i % 4 ? -level : level, i);
        return buf;
      };
      for (let i = 0; i < 15; i += 1) session.onPcm(frame(0));
      for (let i = 0; i < 4; i += 1) session.onPcm(frame(250));
      assert.equal(session.state, "listening");
      session.onPcm(frame(200));
      session.onPcm(frame(0));
      session.onPcm(frame(3000));

      assert.equal(pushed.length, 4);
      if (floor) {
        assert.ok(pcmRms(pushed[0]) >= 1400);
        assert.ok(pcmRms(pushed[1]) >= 1400);
      } else {
        assert.equal(Math.round(pcmRms(pushed[0])), 250);
        assert.equal(Math.round(pcmRms(pushed[1])), 200);
      }
      assert.equal(pcmRms(pushed[2]), 0);
      assert.equal(Math.round(pcmRms(pushed[3])), 3000);
    }
  });

  it("the user's own quiet voice does not raise the bar out of reach", async () => {
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: { async start() {}, push() {} },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* () {
        yield { type: "delta", text: "仓库最近在修登录。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    const frame = (level) => {
      const buf = Buffer.alloc(2560);
      for (let i = 0; i < buf.length; i += 2) buf.writeInt16LE(i % 4 ? -level : level, i);
      return buf;
    };
    for (let i = 0; i < 15; i += 1) session.onPcm(frame(i % 3 ? 0 : 30));
    for (let i = 0; i < 6; i += 1) session.onPcm(frame(90));
    assert.equal(session.state, "speaking");
    for (let i = 0; i < 4; i += 1) session.onPcm(frame(160));
    assert.equal(session.state, "listening");
  });

  it("stays a few seconds ahead of the speaker and drops what a barge cut off", async () => {
    const sends = [];
    const t0 = Date.now();
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: (buf) => sends.push({ at: Date.now() - t0, bytes: buf.length }),
      asr: { async start() {}, push() {} },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* () {
        yield { type: "delta", text: "第一句话说完了。" };
        await new Promise((r) => setTimeout(r, 5));
        yield { type: "delta", text: "第二句话也说完了。" };
        await new Promise((r) => setTimeout(r, 5));
        yield { type: "delta", text: "第三句话不该发出去。" };
        yield { type: "done", engine: "acp", answer: "第一句话说完了。第二句话也说完了。第三句话不该发出去。" };
      },
      tts: async () => Buffer.alloc(48000 * 3),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 300));
    assert.equal(sends.length, 2);
    session.barge();
    await new Promise((r) => setTimeout(r, 2200));
    assert.equal(sends.length, 2);
  });

  it("a leaky speaker keeps the loud bar during playback", async () => {
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: { async start() {}, push() {} },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* () {
        yield { type: "delta", text: "仓库最近在修登录。" };
        yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    const frame = (level) => {
      const buf = Buffer.alloc(2560);
      for (let i = 0; i < buf.length; i += 2) buf.writeInt16LE(i % 4 ? -level : level, i);
      return buf;
    };
    for (let i = 0; i < 15; i += 1) session.onPcm(frame(i % 2 ? 150 : 400));
    for (let i = 0; i < 10; i += 1) session.onPcm(frame(600));
    assert.equal(session.state, "speaking");
  });

  it("a hole in the user's voice during playback still interrupts", async () => {
    const asked = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: { async start() {}, push() {} },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "我是问象，可以帮你看仓库进度，也可以聊天。" };
        yield { type: "done", engine: "acp", answer: "我是问象，可以帮你看仓库进度，也可以聊天。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("你是谁", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(session.state, "speaking");

    const loud = Buffer.alloc(16000 * 2 * 0.2);
    for (let i = 0; i < loud.length; i += 2) loud.writeInt16LE(2500, i);
    const hole = Buffer.alloc(16000 * 2 * 0.4);
    session.onPcm(loud);
    session.onPcm(hole);
    session.onPcm(loud);
    assert.equal(session.state, "listening");

    session.onTranscript("可以帮你看仓库进度", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["你是谁", "可以帮你看仓库进度"]);
  });

  it("after the answer, the next question is heard even if it shares words", async () => {
    const asked = [];
    const pushed = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      asr: {
        async start() {},
        push(buf) {
          pushed.push(buf);
        },
      },
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "我是问象，可以帮你看仓库进度，也可以聊天。" };
        yield { type: "done", engine: "acp", answer: "我是问象，可以帮你看仓库进度，也可以聊天。" };
      },
      tts: async () => Buffer.from("pcm-audio-bytes"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("你是谁", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    session.playbackDone();
    assert.equal(session.state, "listening");

    session.onPcm(loudPcm());
    assert.equal(pushed.length, 1);
    await new Promise((r) => setTimeout(r, 1600));
    session.onTranscript("可以帮你看仓库进度", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["你是谁", "可以帮你看仓库进度"]);
    assert.equal(session.state, "speaking");
  });

  it("keeps the question when a later decode arrives before any speech", async () => {
    const asked = [];
    let aborted = false;
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts, signal) {
        asked.push(opts.question);
        await new Promise((resolve) => {
          const timer = setTimeout(resolve, 400);
          signal?.addEventListener("abort", () => {
            clearTimeout(timer);
            aborted = true;
            resolve();
          }, { once: true });
        });
        if (signal?.aborted) return;
        yield { type: "delta", text: "先说到这里。" };
        yield { type: "done", engine: "acp", answer: "先说到这里。" };
      },
      tts: async () => Buffer.from("pcm"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 20));
    assert.equal(session.state, "thinking");

    const quiet = Buffer.alloc(16000 * 2);
    session.onPcm(quiet);
    session.onTranscript("最近在做什么呢", { final: false });
    session.onTranscript("屋里有点杂音", { final: true });
    await new Promise((r) => setTimeout(r, 30));

    assert.equal(aborted, false);
    assert.deepEqual(asked, ["最近在做什么？"]);
    assert.equal(session.state, "thinking");
    session.hangup();
  });

  it("does not restart the answer when recognition repeats the same line", async () => {
    const asked = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: () => {},
      sendAudio: () => {},
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* (opts) {
        asked.push(opts.question);
        yield { type: "delta", text: "先说到这里。" };
        yield { type: "done", engine: "acp", answer: "先说到这里。" };
      },
      tts: (_text, signal) =>
        new Promise((resolve) => {
          if (signal?.aborted) {
            resolve(Buffer.alloc(0));
            return;
          }
          signal?.addEventListener("abort", () => resolve(Buffer.alloc(0)), { once: true });
        }),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 1300));
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["最近在做什么？"]);

    session.onTranscript("换个话题", { final: true });
    await new Promise((r) => setTimeout(r, 40));
    assert.deepEqual(asked, ["最近在做什么？", "换个话题"]);
    session.hangup();
  });

  it("restarts recognition after one asr failure and stays on the call", async () => {
    const sent = [];
    let starts = 0;
    let stops = 0;
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: (msg) => sent.push(msg),
      asr: {
        async start() {
          starts += 1;
        },
        stop() {
          stops += 1;
        },
      },
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    assert.equal(starts, 1);
    session.onAsrFailure("socket dropped");
    await new Promise((r) => setTimeout(r, 30));

    assert.equal(stops, 1);
    assert.equal(starts, 2);
    assert.equal(sent.some((msg) => msg.type === "error"), false);
    assert.ok(sent.some((msg) => msg.type === "caption" && msg.text === "没听清，再说一次"));
    assert.equal(session.started, true);
    assert.equal(session.state, "listening");
  });

  it("stays on the call when one turn fails", async () => {
    const sent = [];
    const session = createVoiceSession({
      config: { ready: true, provider: "volc" },
      send: (msg) => sent.push(msg),
      checkout: async () => ({ dest: "/tmp/octo/demo" }),
      sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
      ask: async function* () {
        throw new Error("agent down");
      },
      tts: async () => Buffer.from("pcm"),
    });

    await session.start({ owner: "octo", repo: "demo", sessionId: "s1" });
    session.onTranscript("最近在做什么？", { final: true });
    await new Promise((r) => setTimeout(r, 40));

    assert.equal(sent.some((msg) => msg.type === "error"), false);
    assert.ok(sent.some((msg) => msg.type === "caption" && msg.text === "这句没说成，再说一次"));
    assert.equal(session.state, "listening");
  });
});
