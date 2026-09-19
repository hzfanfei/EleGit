import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildBookAcpPrompt } from "../src/acp.js";
import { createBookAskIterator } from "../src/book-voice-turn.js";
import { limitSpokenChinese, spokenContentOnly } from "../src/spoken-limit.js";
import { buildAudioSsePayload, splitTextForTts } from "../src/spoken-tts.js";
import { runVoiceTurn, stripSpokenFiller } from "../src/voice-call.js";

describe("book spoken prompt", () => {
  it("asks for short voice-only replies", () => {
    const prompt = buildBookAcpPrompt({
      question: "这章讲什么？",
      spokenAnswer: true,
    });
    assert.match(prompt, /Spoken reply/);
    assert.match(prompt, /silently/);
    assert.match(prompt, /natural spoken Chinese/);
  });

  it("limits overly long spoken text at punctuation", () => {
    const long = "这是一段很长的回答。".repeat(8);
    const out = limitSpokenChinese(long, { maxChars: 48 });
    assert.ok([...out].length <= 48);
    assert.match(out, /。$/);
  });

  it("strips spoken filler prefixes", () => {
    const out = stripSpokenFiller("简单来说，主角在这一章离开了家乡。");
    assert.equal(out, "主角在这一章离开了家乡。");
  });

  it("drops process sentences and keeps content", () => {
    const out = spokenContentOnly("让我查一下章节。这一章讲的是主角离家。");
    assert.equal(out, "这一章讲的是主角离家。");
  });

  it("drops meta preamble sentences", () => {
    const out = spokenContentOnly("用户询问这本书的内容。这是格鲁夫的《高产出管理》。");
    assert.equal(out, "这是格鲁夫的《高产出管理》。");
  });

  it("gzip-compresses PCM for SSE", () => {
    const pcm = Buffer.alloc(8192, 1);
    const raw = buildAudioSsePayload(pcm, { format: "pcm", codec: "gzip" });
    const plain = buildAudioSsePayload(pcm, { format: "pcm", codec: "raw" });
    assert.equal(raw.codec, "gzip");
    assert.ok(raw.pcm.length < plain.pcm.length);
  });

  it("splits long text for TTS", () => {
    const long = Array.from({ length: 120 }, (_, i) => `\u7b2c${i}\u53e5\u5185\u5bb9\u3002`).join("");
    const parts = splitTextForTts(long);
    assert.ok(parts.length > 1);
    for (const p of parts) assert.ok([...p].length <= 320);
  });
});

describe("book voice turn pipeline", () => {
  it("streams TTS audio from a fake ask", async () => {
    const audio = [];
    const ask = async function* () {
      yield { type: "start", engine: "acp" };
      yield { type: "delta", text: "第一，主角出场。第二，冲突开始。" };
      yield { type: "done", engine: "acp", answer: "第一，主角出场。第二，冲突开始。" };
    };
    await runVoiceTurn({
      question: "概括一下",
      ask,
      tts: async (text) => Buffer.from(`pcm:${text}`, "utf8"),
      onAudio: (buf) => audio.push(buf.toString()),
    });
    assert.ok(audio.length >= 1);
    assert.match(audio.join("|"), /主角出场/);
  });

  it("final speak strategy sends one TTS for cleaned answer", async () => {
    const spoken = [];
    const body = "让我想一下。主角出场，冲突升级。";
    const ask = async function* () {
      yield { type: "delta", text: body };
      yield { type: "done", engine: "acp" };
    };
    await runVoiceTurn({
      question: "q",
      ask,
      speakStrategy: "final",
      limitSpoken: spokenContentOnly,
      tts: async (text) => {
        spoken.push(text);
        return Buffer.from("x");
      },
      onAudio: () => {},
    });
    assert.equal(spoken.length, 1);
    assert.match(spoken[0], /主角出场/);
    assert.doesNotMatch(spoken[0], /让我想一下/);
  });

  it("createBookAskIterator wires spoken prompts", () => {
    const iterator = createBookAskIterator({
      book: { id: "b1", title: "T", author: "A" },
      materialized: { cacheDir: "/tmp", chaptersDir: "/tmp/c" },
      session: { id: "s1" },
      bookSessions: {},
      chapter: "第三章",
      history: [],
      signal: new AbortController().signal,
    });
    assert.equal(typeof iterator, "function");
  });
});
