import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createVoiceSession } from "../src/voice-session.js";

function loudPcm() {
  const buf = Buffer.alloc(640);
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
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(sent.some((m) => m.type === "state" && m.state === "barge"), false);

    session.onTranscript("先停一下", { final: false });
    await new Promise((r) => setTimeout(r, 120));

    assert.equal(sent.some((m) => m.type === "state" && m.state === "barge"), true);
    assert.equal(sent.filter((m) => m.type === "state" && m.state === "listening").length >= 2, true);
    assert.ok(cancelled >= 1);
    assert.ok(ttsCalls >= 1);
    const captions = sent.filter((m) => m.type === "caption");
    assert.equal(captions.some((m) => m.role === "user" && m.text.includes("最近在做什么")), true);
  });
});
