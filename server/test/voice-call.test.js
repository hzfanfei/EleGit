import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createCallMachine, createUtteranceGate, pcmHasSpeech, runVoiceTurn, takeSpeakable } from "../src/voice-call.js";
import { speechTextFromMarkdown } from "../src/spoken-tts.js";

describe("call machine", () => {
  it("walks idle → connecting → listening → speaking → barge → listening", () => {
    const m = createCallMachine();
    assert.equal(m.state, "idle");
    m.start();
    assert.equal(m.state, "connecting");
    m.connected();
    assert.equal(m.state, "listening");
    m.speak();
    assert.equal(m.state, "speaking");
    const action = m.barge();
    assert.equal(action.stopTts, true);
    assert.equal(action.cancelTurn, true);
    assert.equal(m.state, "barge");
    m.afterBarge();
    assert.equal(m.state, "listening");
    m.hangup();
    assert.equal(m.state, "idle");
  });

  it("cancels a turn that is still thinking", () => {
    const m = createCallMachine();
    m.start();
    m.connected();
    m.think();
    assert.equal(m.state, "thinking");
    const action = m.barge();
    assert.equal(action.cancelTurn, true);
    m.afterBarge();
    assert.equal(m.state, "listening");
    m.think();
    m.speak();
    assert.equal(m.state, "speaking");
  });

  it("does not cancel a turn when barging from listening", () => {
    const m = createCallMachine();
    m.start();
    m.connected();
    const action = m.barge();
    assert.equal(action.stopTts, false);
    assert.equal(action.cancelTurn, false);
    assert.equal(m.state, "listening");
  });
});

describe("takeSpeakable", () => {
  it("releases a finished sentence and keeps the tail", () => {
    const first = takeSpeakable("仓库最近在修登录。接下来看 PR");
    assert.equal(first.speak, "仓库最近在修登录。");
    assert.equal(first.rest, "接下来看 PR");
    const hold = takeSpeakable("还没说完");
    assert.equal(hold.speak, "");
    assert.equal(hold.rest, "还没说完");
  });

  it("keeps a comma-heavy sentence together past 72 characters", () => {
    const sentence = `${"这是一句很长的话，中间只有逗号，".repeat(6)}最后才收束。`;
    assert.ok(sentence.length > 72);
    const unfinished = takeSpeakable(sentence.slice(0, -1));
    assert.equal(unfinished.speak, "");
    assert.equal(unfinished.rest, sentence.slice(0, -1));
    const done = takeSpeakable(sentence);
    assert.equal(done.speak, sentence);
    assert.equal(done.rest, "");
  });

  it("does not split one sentence on a semicolon", () => {
    const text = "前半句还没结束；后半句才收束。";
    const chunk = takeSpeakable(text);
    assert.equal(chunk.speak, text);
    assert.equal(chunk.rest, "");
    const mid = takeSpeakable("前半句还没结束；");
    assert.equal(mid.speak, "");
  });
});

function level(ms, amp) {
  const samples = Math.floor((16000 * ms) / 1000);
  const buf = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i += 1) buf.writeInt16LE(amp, i * 2);
  return buf;
}

describe("utterance gate", () => {
  it("keeps a quiet phone sentence across one soft frame and cuts on a pause", async () => {
    const ends = [];
    const gate = createUtteranceGate({
      endpointSilenceMs: 30,
      onEndpoint: (buf) => ends.push(buf.length),
    });
    gate.push(level(180, 800));
    gate.push(level(20, 0));
    gate.push(level(200, 800));
    gate.push(level(40, 0));
    await new Promise((resolve) => setTimeout(resolve, 50));
    assert.equal(ends.length, 1);
    assert.ok(ends[0] > 12800);
  });

  it("does not cut a flat silence", async () => {
    let ends = 0;
    const gate = createUtteranceGate({
      endpointSilenceMs: 20,
      onEndpoint: () => {
        ends += 1;
      },
    });
    gate.push(level(400, 0));
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(ends, 0);
  });

  it("cuts a long stretch even when the level never falls", () => {
    let now = 0;
    let ends = 0;
    const gate = createUtteranceGate({
      maxUtteranceMs: 1000,
      speechStartBytes: 100,
      minEndpointBytes: 100,
      now: () => now,
      onEndpoint: () => {
        ends += 1;
      },
    });
    gate.push(level(40, 2000));
    now = 1001;
    gate.push(level(40, 2000));
    assert.equal(ends, 1);
  });
});

describe("barge energy", () => {
  it("treats loud PCM as speech and silence as not", () => {
    const loud = Buffer.alloc(320);
    for (let i = 0; i < loud.length; i += 2) loud.writeInt16LE(12000, i);
    const quiet = Buffer.alloc(320);
    assert.equal(pcmHasSpeech(loud), true);
    assert.equal(pcmHasSpeech(quiet), false);
  });
});

describe("speech text", () => {
  it("drops Markdown marks, links, tables and code before TTS", () => {
    const md = [
      "===TASK_COMPLETED===",
      "## 登录流程",
      "- **入口**在 `auth.js`，见 [文档](https://example.com/a)。",
      "1. 先校验 token",
      "| 文件 | 作用 |",
      "| --- | --- |",
      "| auth.js | 登录 |",
      "```js",
      "const token = read();",
      "```",
      "---",
      "> 注意 C# 版本和 snake_case 名字",
    ].join("\n");
    assert.equal(
      speechTextFromMarkdown(md),
      ["登录流程", "入口在 auth.js，见 文档。", "先校验 token", "文件，作用", "auth.js，登录", "注意 C# 版本和 snake_case 名字"].join("\n"),
    );
  });

  it("skips a code block that streams in over several sentences", async () => {
    const spoken = [];
    const pieces = ["改的是 **登录**。\n", "```js\nconst a = 1;\n", "if (a) run();\n```\n", "改完就好了。"];
    await runVoiceTurn({
      question: "改了啥",
      ask: async function* () {
        for (const text of pieces) yield { type: "delta", text };
      },
      tts: async (text) => {
        spoken.push(text);
        return Buffer.from([1, 2]);
      },
    });
    assert.deepEqual(spoken, ["改的是 登录。", "改完就好了。"]);
  });

  it("does not read the task marker even when it is glued to the answer", () => {
    assert.equal(speechTextFromMarkdown("===TASK_COMPLETED===默认用小米识别。"), "默认用小米识别。");
  });
});

describe("first words", () => {
  it("says the first clause without waiting for the full stop", () => {
    assert.deepEqual(takeSpeakable("默认用小米的识别，", 320, { firstClause: true }), { speak: "默认用小米的识别，", rest: "" });
    assert.deepEqual(takeSpeakable("嗯，", 320, { firstClause: true }), { speak: "", rest: "嗯，" });
    assert.deepEqual(takeSpeakable("默认用小米的识别，", 320), { speak: "", rest: "默认用小米的识别，" });
  });

  it("sends a streamed sentence to the phone as one clip", async () => {
    const events = [];
    const piece = Buffer.alloc(8000, 1);
    await runVoiceTurn({
      question: "q",
      ask: async function* () {
        yield { type: "delta", text: "我看一下。" };
      },
      tts: async () => {
        throw new Error("whole-sentence TTS should not run");
      },
      ttsStream: async (text, signal, onPcm) => {
        for (let i = 0; i < 4; i += 1) {
          events.push(`synth:${i}`);
          await onPcm(piece);
        }
        events.push("synth:end");
      },
      onAudio: async (buf) => {
        events.push(`play:${buf.length}`);
      },
    });
    assert.deepEqual(events, ["synth:0", "synth:1", "synth:2", "synth:3", "synth:end", "play:32000"]);
  });

  it("falls back to whole-sentence TTS when streaming fails before any audio", async () => {
    const played = [];
    await runVoiceTurn({
      question: "q",
      ask: async function* () {
        yield { type: "delta", text: "好的。" };
      },
      tts: async () => Buffer.from([7, 7]),
      ttsStream: async () => {
        throw new Error("stream down");
      },
      onAudio: async (buf) => {
        played.push([...buf]);
      },
    });
    assert.deepEqual(played, [[7, 7]]);
  });
});
