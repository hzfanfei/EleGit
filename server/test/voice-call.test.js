import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createCallMachine, createUtteranceGate, pcmHasSpeech, takeSpeakable } from "../src/voice-call.js";

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
