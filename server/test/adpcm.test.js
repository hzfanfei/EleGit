import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { decodeAdpcm, encodeAdpcm, isAdpcmPacket } from "../src/adpcm.js";
import { createVoiceSession } from "../src/voice-session.js";

function tone(count) {
  const pcm = Buffer.alloc(count * 2);
  for (let i = 0; i < count; i += 1) {
    const v = 9000 * Math.sin((i * 2 * Math.PI * 440) / 24000) + 3000 * Math.sin((i * 2 * Math.PI * 2100) / 24000);
    pcm.writeInt16LE(Math.round(v), i * 2);
  }
  return pcm;
}

describe("adpcm", () => {
  it("packs call audio to a quarter and decodes close to the source", () => {
    const pcm = tone(24000);
    const packet = encodeAdpcm(pcm, 24000);
    assert.equal(isAdpcmPacket(packet), true);
    assert.ok(packet.length < pcm.length * 0.26);
    const { sampleRate, pcm: back } = decodeAdpcm(packet);
    assert.equal(sampleRate, 24000);
    assert.equal(back.length, pcm.length);
    let sig = 0;
    let noise = 0;
    for (let i = 0; i < pcm.length; i += 2) {
      const a = pcm.readInt16LE(i);
      sig += a * a;
      noise += (a - back.readInt16LE(i)) ** 2;
    }
    assert.ok(10 * Math.log10(sig / noise) > 20);
  });

  it("matches the phone decoder fixture byte for byte", () => {
    const packet = encodeAdpcm(tone(240), 24000);
    assert.equal(
      packet.toString("base64"),
      "V1hBMcBdAADwAAAAAAA2AHAjgKkocyOB28uJEAHazasJEYLJvIpSNBOQmUFGMwKoqjA1BMjMq4gRoN3LmhAigNqbOEYzApgJczQTgLuKMTWQ7buqAALKzbsZMiOg2wpkNCOAmSBVMwG5rQkxAurNugkQgNq8izBEApiaQFVDAZCJIUUSmLyrCA==",
    );
  });

  it("sends adpcm only to phones that ask for it", async () => {
    for (const audio of ["adpcm", undefined]) {
      const sent = [];
      const msgs = [];
      const session = createVoiceSession({
        config: { ready: true, provider: "xiaomi" },
        send: (m) => msgs.push(m),
        sendAudio: (buf) => sent.push(buf),
        asr: { async start() {}, push() {} },
        checkout: async () => ({ dest: "/tmp/octo/demo" }),
        sessions: { resolveForChat: () => ({ id: "s1" }), cancel: async () => {} },
        ask: async function* () {
          yield { type: "delta", text: "仓库最近在修登录。" };
          yield { type: "done", engine: "acp", answer: "仓库最近在修登录。" };
        },
        tts: async () => tone(2400),
      });
      await session.start({ owner: "octo", repo: "demo", sessionId: "s1", audio });
      session.onTranscript("最近在做什么？", { final: true });
      await new Promise((r) => setTimeout(r, 40));
      assert.equal(msgs.find((m) => m.type === "hello")?.audio, audio ? "adpcm" : "pcm");
      assert.equal(sent.length, 1);
      assert.equal(isAdpcmPacket(sent[0]), Boolean(audio));
      assert.equal(sent[0].length, audio ? 16 + 1200 : 4800);
    }
  });
});
