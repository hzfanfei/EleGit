import {
  DEFAULT_VOLC_TTS_VOICE,
  VOLC_TTS_VOICES,
  sanitizeTtsVoice,
} from "./volc-tts-voices.js";

export { DEFAULT_VOLC_TTS_VOICE, VOLC_TTS_VOICES, sanitizeTtsVoice };

function trim(value) {
  return String(value || "").trim();
}

function ttsProviderFromEnv(env) {
  const raw = trim(env.WENXIANG_TTS_PROVIDER).toLowerCase();
  if (raw === "cosyvoice" || raw === "local") return "cosyvoice";
  const flag = trim(env.WENXIANG_COSYVOICE_TTS).toLowerCase();
  if (flag === "1" || flag === "true" || flag === "yes" || trim(env.COSYVOICE_TTS_ENABLED) === "1") {
    return "cosyvoice";
  }
  return "volc";
}

function asrProviderFromEnv(env) {
  const raw = trim(env.WENXIANG_ASR_PROVIDER).toLowerCase();
  if (raw === "funasr" || raw === "local") return "funasr";
  const flag = trim(env.WENXIANG_FUNASR_ASR).toLowerCase();
  if (flag === "1" || flag === "true" || flag === "yes" || trim(env.FUNASR_ASR_ENABLED) === "1") {
    return "funasr";
  }
  return "volc";
}

function volcTtsLoudnessRate(env) {
  const raw = trim(env.VOLC_TTS_LOUDNESS_RATE);
  if (!raw) return 75;
  const n = Number(raw);
  if (!Number.isFinite(n)) return 75;
  return Math.max(-50, Math.min(100, Math.round(n)));
}

export function resolveVoiceConfig(env = process.env) {
  const appId = trim(env.VOLC_APP_ID || env.DOUBAO_APP_ID || env.VOLCENGINE_APP_ID);
  const accessToken = trim(
    env.VOLC_ACCESS_TOKEN ||
      env.DOUBAO_ACCESS_KEY ||
      env.VOLC_ACCESS_KEY ||
      env.VOLCENGINE_ACCESS_TOKEN,
  );
  const apiKey = trim(env.VOLC_API_KEY);
  const openaiKey = trim(env.OPENAI_API_KEY);

  if (appId && accessToken) {
    return readyVolc({ appId, accessToken, apiKey, env });
  }
  if (apiKey) {
    return readyVolc({ appId, accessToken, apiKey, env });
  }
  if (openaiKey) {
    return {
      ready: true,
      provider: "openai",
      hint: "",
      openai: {
        apiKey: openaiKey,
        realtimeModel: trim(env.OPENAI_REALTIME_MODEL) || "gpt-4o-realtime-preview",
        ttsModel: trim(env.OPENAI_TTS_MODEL) || "gpt-4o-mini-tts",
        ttsVoice: trim(env.OPENAI_TTS_VOICE) || "alloy",
      },
      volc: null,
    };
  }
  return {
    ready: false,
    provider: null,
    hint: "还没配语音密钥。请在本机问象服务的 .env 里配置。",
    volc: null,
    openai: null,
  };
}

function readyVolc({ appId, accessToken, apiKey, env }) {
  const ttsProvider = ttsProviderFromEnv(env);
  const asrProvider = asrProviderFromEnv(env);
  return {
    ready: true,
    provider: "volc",
    ttsProvider,
    asrProvider,
    cosyvoice: ttsProvider === "cosyvoice" ? { enabled: true } : null,
    funasr: asrProvider === "funasr" ? { enabled: true } : null,
    hint: "",
    volc: {
      appId,
      accessToken,
      apiKey,
      asrResourceId: trim(env.VOLC_ASR_RESOURCE_ID) || "volc.bigasr.sauc.duration",
      asrUrl: trim(env.VOLC_ASR_URL) || "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel",
      ttsResourceId: trim(env.VOLC_TTS_RESOURCE_ID),
      ttsModel: trim(env.VOLC_TTS_MODEL),
      ttsUrl:
        trim(env.VOLC_TTS_URL) ||
        (trim(env.VOLC_TTS_RESOURCE_ID)
          ? "https://openspeech.bytedance.com/api/v3/tts/unidirectional"
          : "https://openspeech.bytedance.com/api/v1/tts"),
      ttsCluster: trim(env.VOLC_TTS_CLUSTER) || "volcano_tts",
      ttsVoice: sanitizeTtsVoice(env.VOLC_TTS_VOICE) || DEFAULT_VOLC_TTS_VOICE,
      /** v3 TTS: pcm (SSE gzip) or mp3 — set VOLC_TTS_FORMAT=mp3 to opt in */
      ttsFormat: trim(env.VOLC_TTS_FORMAT) || "pcm",
      /** V3 loudness_rate -50..100 (0=normal, 50≈1.5×, 100=2×). V1 uses derived volume_ratio. */
      ttsLoudnessRate: volcTtsLoudnessRate(env),
    },
    openai: null,
  };
}

export function resolveTurnTtsVoice(requested, stored) {
  return sanitizeTtsVoice(requested) || sanitizeTtsVoice(stored) || "";
}

export function withTtsVoice(config, rawVoice) {
  const voice = sanitizeTtsVoice(rawVoice);
  if (!voice || !config) return config;
  if (config.volc) {
    return { ...config, volc: { ...config.volc, ttsVoice: voice } };
  }
  if (config.openai) {
    return { ...config, openai: { ...config.openai, ttsVoice: voice } };
  }
  return config;
}

export function publicVoiceStatus(config = resolveVoiceConfig()) {
  const ttsProvider = config.ttsProvider || "volc";
  const asrProvider = config.asrProvider || "volc";
  return {
    ready: Boolean(config.ready),
    hint: config.ready ? "" : config.hint || "还没配语音密钥。请在本机问象服务的 .env 里配置。",
    asrProvider,
    asrEngine: asrProvider === "funasr" ? "FunASR-Paraformer" : "volc",
    ttsProvider,
    ttsEngine: ttsProvider === "cosyvoice" ? "Fun-CosyVoice3" : "volc",
    ttsVoice: config.volc?.ttsVoice || DEFAULT_VOLC_TTS_VOICE,
    voices: VOLC_TTS_VOICES,
  };
}
