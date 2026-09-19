import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DEFAULT_VOLC_TTS_VOICE,
  publicVoiceStatus,
  resolveVoiceConfig,
  resolveTurnTtsVoice,
  sanitizeTtsVoice,
  withTtsVoice,
} from "../src/voice-config.js";

describe("resolveVoiceConfig", () => {
  it("is not ready and hints in Chinese when no voice keys exist", () => {
    const cfg = resolveVoiceConfig({});
    assert.equal(cfg.ready, false);
    assert.equal(cfg.provider, null);
    assert.match(cfg.hint, /还没配语音密钥/);
    const pub = publicVoiceStatus(cfg);
    assert.equal(pub.ready, false);
    assert.match(pub.hint, /还没配语音密钥/);
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

  it("defaults Volcengine TTS to 小何 2.0", () => {
    assert.equal(DEFAULT_VOLC_TTS_VOICE, "zh_female_xiaohe_uranus_bigtts");
    const cfg = resolveVoiceConfig({ VOLC_API_KEY: "ak-only" });
    assert.equal(cfg.volc.ttsVoice, "zh_female_xiaohe_uranus_bigtts");
    const pub = publicVoiceStatus(cfg);
    assert.equal(pub.ttsVoice, "zh_female_xiaohe_uranus_bigtts");
    assert.ok(pub.voices.some((v) => v.id === "zh_female_xiaohe_uranus_bigtts" && v.name.includes("小何")));
  });

  it("keeps an explicit VOLC_TTS_VOICE", () => {
    const cfg = resolveVoiceConfig({
      VOLC_API_KEY: "ak-only",
      VOLC_TTS_VOICE: " zh_male_m191_uranus_bigtts ",
    });
    assert.equal(cfg.volc.ttsVoice, "zh_male_m191_uranus_bigtts");
    assert.equal(publicVoiceStatus(cfg).ttsVoice, "zh_male_m191_uranus_bigtts");
  });
});

describe("tts voice override", () => {
  it("accepts official speaker ids and rejects junk", () => {
    assert.equal(sanitizeTtsVoice("zh_female_xiaohe_uranus_bigtts"), "zh_female_xiaohe_uranus_bigtts");
    assert.equal(sanitizeTtsVoice("  zh_male_m191_uranus_bigtts "), "zh_male_m191_uranus_bigtts");
    assert.equal(sanitizeTtsVoice(""), "");
    assert.equal(sanitizeTtsVoice("http://evil"), "");
    assert.equal(sanitizeTtsVoice("zh female"), "");
  });

  it("overrides the Volcengine speaker for one turn without mutating the base config", () => {
    const cfg = resolveVoiceConfig({ VOLC_API_KEY: "ak-only" });
    const next = withTtsVoice(cfg, "zh_male_m191_uranus_bigtts");
    assert.equal(next.volc.ttsVoice, "zh_male_m191_uranus_bigtts");
    assert.equal(cfg.volc.ttsVoice, "zh_female_xiaohe_uranus_bigtts");
    assert.equal(withTtsVoice(cfg, "not a voice").volc.ttsVoice, "zh_female_xiaohe_uranus_bigtts");
  });

  it("prefers the request voice, then the saved setting", () => {
    assert.equal(
      resolveTurnTtsVoice("zh_male_m191_uranus_bigtts", "zh_female_vv_uranus_bigtts"),
      "zh_male_m191_uranus_bigtts",
    );
    assert.equal(resolveTurnTtsVoice("", "zh_female_vv_uranus_bigtts"), "zh_female_vv_uranus_bigtts");
    assert.equal(resolveTurnTtsVoice("not a voice", ""), "");
  });
});
