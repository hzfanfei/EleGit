import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { probeVoiceTts, runDiagnosticsProbe } from "../src/diagnostics.js";

describe("diagnostics", () => {
  it("reports voice not configured without keys", async () => {
    const prev = { ...process.env };
    for (const key of [
      "VOLC_APP_ID",
      "VOLC_ACCESS_TOKEN",
      "VOLC_API_KEY",
      "OPENAI_API_KEY",
      "DOUBAO_APP_ID",
      "DOUBAO_ACCESS_KEY",
    ]) {
      delete process.env[key];
    }
    try {
      const tts = await probeVoiceTts({});
      assert.equal(tts.ok, false);
      assert.match(String(tts.error || ""), /语音|密钥|配置/);
      const all = await runDiagnosticsProbe({
        askCli: false,
        askModel: false,
        voiceTts: true,
        voiceStt: false,
      });
      assert.equal(all.voiceTts?.ok, false);
    } finally {
      process.env = prev;
    }
  });
});
