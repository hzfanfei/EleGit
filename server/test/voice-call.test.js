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
