import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildBookAcpPrompt } from "../src/acp.js";
import { createBookAskIterator } from "../src/book-voice-turn.js";
import { buildAudioSsePayload, isSpeakableTtsText, splitTextForTts } from "../src/spoken-tts.js";
import { runVoiceTurn } from "../src/voice-call.js";

describe("book spoken prompt", () => {
  it("asks for direct answers without process narration", () => {
    const prompt = buildBookAcpPrompt({
      question: "这章讲什么？",
      spokenAnswer: true,
    });
    assert.match(prompt, /只输出答案正文/);
    assert.match(prompt, /语音朗读/);
    assert.match(prompt, /正反例/);
    assert.match(prompt, /本题作答/);
    assert.match(prompt, /这章讲什么/);
  });

  it("text book chat uses the same direct-answer root rules", () => {
    const prompt = buildBookAcpPrompt({ question: "主角是谁？" });
    assert.match(prompt, /禁止以这些开头/);
    assert.doesNotMatch(prompt, /语音朗读/);
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

  it("treats punctuation-only text as unreadable for TTS", () => {
    assert.equal(isSpeakableTtsText("……"), false);
    assert.equal(isSpeakableTtsText("***"), false);
    assert.equal(isSpeakableTtsText("你好。"), true);
    assert.equal(isSpeakableTtsText("OK"), true);
  });
});

describe("book voice turn pipeline", () => {
  it("streams TTS from model text as-is", async () => {
    const spoken = [];
    const ask = async function* () {
      yield { type: "delta", text: "让我查一下。主角在这一章出场。" };
      yield { type: "done", engine: "acp" };
    };
    await runVoiceTurn({
      question: "q",
      ask,
      speakStrategy: "stream",
      tts: async (text) => {
        spoken.push(text);
        return Buffer.from("x");
      },
      onAudio: () => {},
    });
    assert.ok(spoken.length >= 1);
    assert.ok(spoken.join("").includes("让我查一下"));
  });

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

  it("final speak strategy sends one TTS for full answer", async () => {
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
      tts: async (text) => {
        spoken.push(text);
        return Buffer.from("x");
      },
      onAudio: () => {},
    });
    assert.equal(spoken.length, 1);
    assert.match(spoken[0], /让我想一下/);
    assert.match(spoken[0], /主角出场/);
  });

  it("skips punctuation-only TTS and does not crash on No readable text", async () => {
    const spoken = [];
    const ask = async function* () {
      yield { type: "delta", text: "……" };
      yield { type: "delta", text: "***" };
      yield { type: "done", engine: "acp" };
    };
    await assert.rejects(
      () =>
        runVoiceTurn({
          question: "q",
          ask,
          speakStrategy: "stream",
          tts: async (text) => {
            spoken.push(text);
            const err = new Error("No readable text");
            throw err;
          },
          onAudio: () => {},
        }),
      (err) => err.code === "empty_answer",
    );
    assert.equal(spoken.length, 0);
  });

  it("swallows No readable text on a junk clause and still speaks the rest", async () => {
    const spoken = [];
    const audio = [];
    const ask = async function* () {
      yield { type: "delta", text: "第一句。" };
      yield { type: "delta", text: "第二句。" };
      yield { type: "done", engine: "acp" };
    };
    await runVoiceTurn({
      question: "q",
      ask,
      speakStrategy: "stream",
      tts: async (text) => {
        spoken.push(text);
        if (text.includes("第一")) {
          throw new Error("No readable text");
        }
        return Buffer.from("x");
      },
      onAudio: (buf) => audio.push(buf),
    });
    assert.deepEqual(spoken, ["第一句。", "第二句。"]);
    assert.equal(audio.length, 1);
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
