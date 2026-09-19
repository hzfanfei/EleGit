import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { existsSync, mkdirSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { probeAskCli, probeVoiceTts, runDiagnosticsProbe } from "../src/diagnostics.js";

describe("diagnostics", () => {
  it("creates probe cwd under workspace before ACP spawn", async () => {
    const root = path.join(os.tmpdir(), `wenxiang-probe-${Date.now()}`);
    mkdirSync(root, { recursive: true });
    try {
      const result = await probeAskCli({ cwd: root });
      assert.equal(typeof result.ok, "boolean");
      assert.ok(existsSync(path.join(root, ".diagnostics-probe")));
    } finally {
      try {
        rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
      } catch {
        // Windows may still hold handles briefly after ACP probe; ignore teardown EPERM.
      }
    }
  });

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
