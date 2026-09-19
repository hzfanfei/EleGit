import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  BOOK_VOICE_CLIENT_WAITS_FOR_DONE,
  BOOK_VOICE_SPEAK_STRATEGY,
  diagnoseBookVoiceLatency,
  formatLatencyComparison,
  formatLatencyDiagnosis,
} from "../src/book-voice-latency.js";
import { runVoiceTurn } from "../src/voice-call.js";

const delay = (ms) => new Promise((r) => setTimeout(r, ms));

describe("book voice latency diagnosis", () => {
  it("matches production wiring (stream TTS + client plays on audio)", () => {
    assert.equal(BOOK_VOICE_SPEAK_STRATEGY, "stream");
    assert.equal(BOOK_VOICE_CLIENT_WAITS_FOR_DONE, false);
  });

  it("measures think vs TTS and explains why first audio is late", async () => {
    const markers = [];
    const mark = (phase) => markers.push({ phase, atMs: performance.now() });

    const thinkMs = 120;
    const ttsMs = 80;

    mark("turn_start");
    const ask = async function* () {
      mark("ask_start");
      await delay(thinkMs);
      yield { type: "delta", text: "让我查一下。这一章讲的是主角离家。" };
      yield { type: "done", engine: "acp" };
      mark("ask_done");
    };

    await runVoiceTurn({
      question: "这章讲什么",
      ask,
      speakStrategy: "final",
      tts: async () => {
        mark("tts_start");
        await delay(ttsMs);
        mark("tts_done");
        return Buffer.from("pcm");
      },
      onAudio: () => mark("first_audio"),
      onDone: () => mark("turn_done"),
    });

    const report = diagnoseBookVoiceLatency(markers, {
      speakStrategy: "final",
      clientWaitsForDone: true,
    });

    assert.ok(report.timeToFirstAudioMs != null);
    assert.ok(report.timeToFirstAudioMs >= thinkMs - 5, "首包音频不应早于 ACP 结束");
    assert.ok(
      report.buckets.ttsAfterAskUntilFirstAudio >= ttsMs - 10,
      "首包音频应包含 TTS 耗时",
    );
    assert.equal(report.dominant, "think_acp");

    const text = formatLatencyDiagnosis(report);
    assert.match(text, /speakStrategy=final/);
    assert.match(text, /整段回答/);

    // Visible in `node --test` output when diagnosing long waits.
    console.log("\n" + text + "\n");
  });

  it("stream strategy would emit audio before ask finishes (contrast)", async () => {
    const markers = [];
    const mark = (phase) => markers.push({ phase, atMs: performance.now() });

    const ask = async function* () {
      mark("ask_start");
      yield { type: "delta", text: "第一句。" };
      await delay(100);
      yield { type: "delta", text: "第二句。" };
      mark("ask_done");
      yield { type: "done", engine: "acp" };
    };

    await runVoiceTurn({
      question: "q",
      ask,
      speakStrategy: "stream",
      tts: async () => {
        mark("tts_done");
        return Buffer.from("pcm");
      },
      onAudio: () => mark("first_audio"),
      onDone: () => mark("turn_done"),
    });

    const askDone = markers.find((m) => m.phase === "ask_done")?.atMs;
    const firstAudio = markers.find((m) => m.phase === "first_audio")?.atMs;
    assert.ok(askDone != null && firstAudio != null);
    assert.ok(firstAudio < askDone, "stream 模式首包音频应早于 ask_done");

    const report = diagnoseBookVoiceLatency(markers, {
      speakStrategy: "stream",
      clientWaitsForDone: true,
    });
    assert.match(report.reasons.join("\n"), /stream/);
  });

  it("side-by-side: old final+done vs new stream+audio (same simulated ACP)", async () => {
    const firstTokenMs = 650;
    const askDoneMs = 2400;
    const ttsMs = 180;

    const makeAsk = () =>
      async function* () {
        const t0 = performance.now();
        const waitUntil = (target) => delay(Math.max(0, target - (performance.now() - t0)));
        await waitUntil(firstTokenMs);
        yield { type: "delta", text: "这一章讲的是主角离家。" };
        await waitUntil(askDoneMs);
        yield { type: "delta", text: "后面还有冲突升级。" };
        yield { type: "done", engine: "acp" };
      };

    async function runProfile({ label, speakStrategy, clientWaitsForDone }) {
      const markers = [];
      const mark = (phase) => markers.push({ phase, atMs: performance.now() });
      mark("turn_start");
      await runVoiceTurn({
        question: "这章讲什么",
        ask: makeAsk(),
        speakStrategy,
        tts: async () => {
          await delay(ttsMs);
          return Buffer.from("pcm");
        },
        onAudio: () => {
          if (!markers.some((m) => m.phase === "first_audio")) mark("first_audio");
        },
        onDone: () => mark("turn_done"),
      });
      // ask_done approximated from simulated ACP timeline
      const t0 = markers[0].atMs;
      markers.push({ phase: "ask_done", atMs: t0 + askDoneMs });
      return {
        label,
        ...diagnoseBookVoiceLatency(markers, { speakStrategy, clientWaitsForDone }),
      };
    }

    const oldProfile = await runProfile({
      label: "旧: final + App 等 done",
      speakStrategy: "final",
      clientWaitsForDone: true,
    });
    const newProfile = await runProfile({
      label: "新: stream + App 即播",
      speakStrategy: "stream",
      clientWaitsForDone: false,
    });
    const prodProfile = await runProfile({
      label: "现网配置",
      speakStrategy: BOOK_VOICE_SPEAK_STRATEGY,
      clientWaitsForDone: BOOK_VOICE_CLIENT_WAITS_FOR_DONE,
    });

    const table = formatLatencyComparison([oldProfile, newProfile, prodProfile]);
    console.log("\n" + table + "\n");

    assert.ok(
      (newProfile.userPerceivedFirstSoundMs ?? 0) < (oldProfile.userPerceivedFirstSoundMs ?? 0),
      "新方案首声应早于旧方案",
    );
    assert.equal(prodProfile.speakStrategy, "stream");
    assert.equal(prodProfile.clientWaitsForDone, false);
    assert.ok(
      (prodProfile.userPerceivedFirstSoundMs ?? 0) <= (newProfile.userPerceivedFirstSoundMs ?? 0) + 50,
    );
  });

  it("client done-gating adds perceived wait after first audio on the wire", () => {
    const report = diagnoseBookVoiceLatency(
      [
        { phase: "turn_start", atMs: 0 },
        { phase: "ask_done", atMs: 3000 },
        { phase: "first_audio", atMs: 3800 },
        { phase: "turn_done", atMs: 3900 },
      ],
      { speakStrategy: "final", clientWaitsForDone: true },
    );
    assert.equal(report.buckets.sseAfterFirstAudioUntilDone, 100);
    assert.match(formatLatencyDiagnosis(report), /用户感知等待/);
  });
});
