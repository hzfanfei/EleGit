import { isSpeakableTtsText } from "./spoken-tts.js";
import {
  DEFAULT_XIAOMI_TTS_VOICE,
  isXiaomiTtsVoice,
  xiaomiApiVoice,
} from "./xiaomi-tts-voices.js";

export const XIAOMI_SPEECH_URL = "https://token-plan-cn.xiaomimimo.com/v1/chat/completions";
export const XIAOMI_TTS_MODEL = "mimo-v2.5-tts";
export const XIAOMI_ASR_MODEL = "mimo-v2.5-asr";

const TTS_STYLE = "用自然、清晰的中文说。";
const MAX_WAV_BYTES = 8 * 1024 * 1024;
const ENDPOINT_SILENCE_MS = 900;
const MIN_ENDPOINT_BYTES = 16000 * 2;

function trim(value) {
  return String(value || "").trim();
}

export function xiaomiSpeechFromEnv(env = process.env) {
  const apiKey = trim(env.XIAOMI_MIMO_TOKEN);
  if (!apiKey) return null;
  return {
    enabled: true,
    apiKey,
    baseUrl: trim(env.XIAOMI_MIMO_BASE_URL) || XIAOMI_SPEECH_URL,
    ttsModel: trim(env.XIAOMI_TTS_MODEL) || XIAOMI_TTS_MODEL,
    asrModel: trim(env.XIAOMI_ASR_MODEL) || XIAOMI_ASR_MODEL,
    ttsVoice: DEFAULT_XIAOMI_TTS_VOICE,
    asrLanguage: "zh",
    inputRate: 16000,
  };
}

function speechHeaders(apiKey) {
  return {
    Authorization: `Bearer ${apiKey}`,
    "api-key": apiKey,
    "Content-Type": "application/json",
  };
}

async function postSpeech(xiaomi, body, signal, fetchImpl) {
  const res = await fetchImpl(xiaomi.baseUrl || XIAOMI_SPEECH_URL, {
    method: "POST",
    headers: speechHeaders(xiaomi.apiKey),
    body: JSON.stringify(body),
    signal,
  });
  const raw = await res.text();
  let json = null;
  try {
    json = raw ? JSON.parse(raw) : null;
  } catch {
    json = null;
  }
  if (!res.ok) {
    const err = new Error(
      res.status === 401 || res.status === 403
        ? "xiaomi speech unauthorized"
        : `xiaomi speech failed (${res.status})`,
    );
    err.status = res.status;
    throw err;
  }
  return json;
}

/** PCM16 mono WAV. Xiaomi TTS returns 24 kHz; the phone records ASR at 16 kHz. */
export function pcm16ToWav(pcm, sampleRate = 16000) {
  const data = Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm || []);
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + data.length, 4);
  header.write("WAVE", 8);
  header.write("fmt ", 12);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(1, 22);
  header.writeUInt32LE(sampleRate, 24);
  header.writeUInt32LE(sampleRate * 2, 28);
  header.writeUInt16LE(2, 32);
  header.writeUInt16LE(16, 34);
  header.write("data", 36);
  header.writeUInt32LE(data.length, 40);
  return Buffer.concat([header, data]);
}

export function pcm16FromWav(wav) {
  const data = Buffer.isBuffer(wav) ? wav : Buffer.from(wav || []);
  if (data.length < 44 || data.toString("ascii", 0, 4) !== "RIFF") {
    return { pcm: data, sampleRate: 24000 };
  }
  let offset = 12;
  let sampleRate = 24000;
  while (offset + 8 <= data.length) {
    const id = data.toString("ascii", offset, offset + 4);
    const size = data.readUInt32LE(offset + 4);
    const start = offset + 8;
    if (id === "fmt " && start + 8 <= data.length) {
      sampleRate = data.readUInt32LE(start + 4) || sampleRate;
    } else if (id === "data") {
      const end = Math.min(data.length, start + size);
      return { pcm: Buffer.from(data.subarray(start, end)), sampleRate };
    }
    offset = start + size + (size % 2);
  }
  return { pcm: Buffer.alloc(0), sampleRate };
}

export async function xiaomiTts(xiaomi, text, signal, fetchImpl = fetch) {
  const spoken = String(text || "").trim();
  if (!isSpeakableTtsText(spoken)) return Buffer.alloc(0);
  const voiceId = isXiaomiTtsVoice(xiaomi?.ttsVoice) ? xiaomi.ttsVoice : DEFAULT_XIAOMI_TTS_VOICE;
  const json = await postSpeech(
    xiaomi,
    {
      model: xiaomi?.ttsModel || XIAOMI_TTS_MODEL,
      messages: [
        { role: "user", content: TTS_STYLE },
        { role: "assistant", content: spoken },
      ],
      audio: { format: "wav", voice: xiaomiApiVoice(voiceId) },
    },
    signal,
    fetchImpl,
  );
  const b64 = json?.choices?.[0]?.message?.audio?.data || "";
  if (!b64) {
    const err = new Error("xiaomi tts empty");
    err.status = 502;
    throw err;
  }
  return pcm16FromWav(Buffer.from(b64, "base64")).pcm;
}

export async function xiaomiAsrTranscribe(xiaomi, pcm, { sampleRate = 16000, signal, fetchImpl = fetch } = {}) {
  const audio = Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm || []);
  if (!audio.length) return "";
  const wav = pcm16ToWav(audio, sampleRate);
  if (wav.length > MAX_WAV_BYTES) {
    const err = new Error("录音太长");
    err.status = 413;
    throw err;
  }
  const json = await postSpeech(
    xiaomi,
    {
      model: xiaomi?.asrModel || XIAOMI_ASR_MODEL,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "input_audio",
              input_audio: { data: `data:audio/wav;base64,${wav.toString("base64")}` },
            },
          ],
        },
      ],
      asr_options: { language: xiaomi?.asrLanguage || "zh" },
    },
    signal,
    fetchImpl,
  );
  const content = json?.choices?.[0]?.message?.content;
  if (Array.isArray(content)) {
    return content.map((part) => (typeof part === "string" ? part : part?.text || "")).join("").trim();
  }
  return String(content || "").trim();
}

export function createXiaomiAsr({
  xiaomi,
  pushToTalk = false,
  onFinal,
  onError,
  fetchImpl = fetch,
} = {}) {
  const chunks = [];
  let started = false;
  let endpointTimer = null;
  let chain = Promise.resolve();

  function pcmBuffer() {
    return chunks.length ? Buffer.concat(chunks) : Buffer.alloc(0);
  }

  function clearEndpoint() {
    if (endpointTimer) {
      clearTimeout(endpointTimer);
      endpointTimer = null;
    }
  }

  function transcribe(buf) {
    chain = chain
      .then(async () => {
        if (!buf.length) {
          onFinal?.("");
          return;
        }
        const text = await xiaomiAsrTranscribe(xiaomi, buf, {
          sampleRate: xiaomi?.inputRate || 16000,
          fetchImpl,
        });
        onFinal?.(text);
      })
      .catch((err) => {
        onError?.({ message: String(err.message || err), err });
      });
    return chain;
  }

  function scheduleEndpoint() {
    if (pushToTalk) return;
    clearEndpoint();
    if (!started) return;
    endpointTimer = setTimeout(() => {
      if (!started || pcmBuffer().length < MIN_ENDPOINT_BYTES) return;
      const buf = pcmBuffer();
      chunks.length = 0;
      transcribe(buf);
    }, ENDPOINT_SILENCE_MS);
  }

  return {
    async start() {
      chunks.length = 0;
      started = true;
      chain = Promise.resolve();
      clearEndpoint();
    },
    push(pcm) {
      if (!started || !pcm) return;
      chunks.push(Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm));
      scheduleEndpoint();
    },
    stop() {
      started = false;
      clearEndpoint();
      chunks.length = 0;
    },
    async finalize() {
      started = false;
      clearEndpoint();
      const buf = pcmBuffer();
      chunks.length = 0;
      await transcribe(buf);
    },
  };
}
