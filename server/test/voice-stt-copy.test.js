import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { sttErrorFromFailure, sttErrorFromVolcFrame } from "../src/voice-stt-copy.js";

describe("voice stt copy", () => {
  it("maps timeout to network hint", () => {
    const mapped = sttErrorFromFailure(new Error("asr timeout"));
    assert.equal(mapped.code, "network");
    assert.match(mapped.hint, /超时/);
  });

  it("maps auth failures", () => {
    const mapped = sttErrorFromFailure(new Error("HTTP 401 Unauthorized"));
    assert.equal(mapped.code, "asr_auth");
    assert.match(mapped.hint, /密钥/);
  });

  it("maps volc resource errors", () => {
    const mapped = sttErrorFromVolcFrame({ type: "error", code: 403, message: "resource not granted" });
    assert.equal(mapped.code, "asr_resource");
    assert.match(mapped.hint, /资源/);
  });
});
