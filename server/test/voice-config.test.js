import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { publicVoiceStatus, resolveVoiceConfig } from "../src/voice-config.js";

describe("resolveVoiceConfig", () => {
  it("is not ready and hints in Chinese when no voice keys exist", () => {
    const cfg = resolveVoiceConfig({});
    assert.equal(cfg.ready, false);
    assert.equal(cfg.provider, null);
    assert.equal(cfg.hint, "还没配语音密钥");
    const pub = publicVoiceStatus(cfg);
    assert.deepEqual(pub, { ready: false, hint: "还没配语音密钥" });
    assert.ok(!JSON.stringify(pub).includes("VOLC"));
    assert.ok(!JSON.stringify(pub).includes("openai"));
  });

  it("prefers Volcengine when app id and access token are present", () => {
    const cfg = resolveVoiceConfig({
      VOLC_APP_ID: "  app-1 ",
      VOLC_ACCESS_TOKEN: "tok-1",
      OPENAI_API_KEY: "sk-should-not-win",
    });
    assert.equal(cfg.ready, true);
    assert.equal(cfg.provider, "volc");
    assert.equal(cfg.hint, "");
    assert.equal(cfg.volc.appId, "app-1");
    assert.equal(cfg.volc.accessToken, "tok-1");
    assert.equal(publicVoiceStatus(cfg).ready, true);
    assert.equal(publicVoiceStatus(cfg).hint, "");
    assert.ok(!Object.hasOwn(publicVoiceStatus(cfg), "provider"));
  });

  it("accepts Doubao aliases and a lone new-console API key", () => {
    const aliased = resolveVoiceConfig({
      DOUBAO_APP_ID: "doubao-app",
      DOUBAO_ACCESS_KEY: "doubao-tok",
    });
    assert.equal(aliased.ready, true);
    assert.equal(aliased.provider, "volc");
    assert.equal(aliased.volc.appId, "doubao-app");

    const modern = resolveVoiceConfig({ VOLC_API_KEY: "ak-only" });
    assert.equal(modern.ready, true);
    assert.equal(modern.provider, "volc");
    assert.equal(modern.volc.apiKey, "ak-only");
  });

  it("falls back to OpenAI Realtime when Volcengine keys are missing", () => {
    const cfg = resolveVoiceConfig({ OPENAI_API_KEY: "sk-test" });
    assert.equal(cfg.ready, true);
    assert.equal(cfg.provider, "openai");
    assert.equal(cfg.openai.apiKey, "sk-test");
    assert.equal(cfg.openai.realtimeModel, "gpt-4o-realtime-preview");
  });
});
