import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createCallMachine, pcmHasSpeech, takeSpeakable } from "../src/voice-call.js";

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

describe("barge energy", () => {
  it("treats loud PCM as speech and silence as not", () => {
    const loud = Buffer.alloc(320);
    for (let i = 0; i < loud.length; i += 2) loud.writeInt16LE(12000, i);
    const quiet = Buffer.alloc(320);
    assert.equal(pcmHasSpeech(loud), true);
    assert.equal(pcmHasSpeech(quiet), false);
  });
});
