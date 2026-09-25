import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { ensureFunasrAsrWorker, shutdownFunasrAsrWorker } from "../src/funasr-asr.js";
import { ensureCosyVoiceTtsWorker, shutdownCosyVoiceTtsWorker } from "../src/cosyvoice-tts.js";
import { readReadyHealth } from "../src/worker-health.js";

describe("voice worker adopt", () => {
  it("reads a ready health payload and ignores a down worker", async () => {
    const ready = await readReadyHealth("http://127.0.0.1:9", async () => ({
      ok: true,
      json: async () => ({ ready: true, device: "cuda:0" }),
    }));
    const down = await readReadyHealth("http://127.0.0.1:9", async () => {
      throw new Error("refused");
    });
    assert.equal(ready.device, "cuda:0");
    assert.equal(down, null);
  });

  it("does not spawn FunASR when one is already ready", async () => {
    let spawned = 0;
    try {
      const layout = await ensureFunasrAsrWorker(
        { FUNASR_ASR_URL: "http://127.0.0.1:9" },
        {
          fetchImpl: async () => ({
            ok: true,
            json: async () => ({ ready: true, device: "cuda:0", load_ms: 12 }),
          }),
          spawnImpl: () => {
            spawned += 1;
            throw new Error("should not spawn");
          },
        },
      );
      assert.equal(spawned, 0);
      assert.equal(layout.health.device, "cuda:0");
    } finally {
      shutdownFunasrAsrWorker();
    }
  });

  it("does not spawn CosyVoice when one is already ready", async () => {
    let spawned = 0;
    try {
      const layout = await ensureCosyVoiceTtsWorker(
        { COSYVOICE_TTS_URL: "http://127.0.0.1:9" },
        {
          fetchImpl: async () => ({
            ok: true,
            json: async () => ({ ready: true, device: "cuda", default_spk: "zh" }),
          }),
          spawnImpl: () => {
            spawned += 1;
            throw new Error("should not spawn");
          },
        },
      );
      assert.equal(spawned, 0);
      assert.equal(layout.defaultSpkId, "zh");
    } finally {
      shutdownCosyVoiceTtsWorker();
    }
  });
});
