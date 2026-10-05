import WebSocket from "ws";
import { CALL_MIN_RMS, createUtteranceGate } from "./voice-call.js";
import { isSpeakableTtsText } from "./spoken-tts.js";
import { pcm16ToWav } from "./xiaomi-speech.js";
import { DEFAULT_MINIMAX_TTS_VOICE, isMinimaxTtsVoice } from "./minimax-tts-voices.js";

export const MINIMAX_API_HOST = "api.minimax.cn";
export const MINIMAX_TTS_MODEL = "speech-2.8-turbo";
export const MINIMAX_ASR_MODEL = "asr-1.0";
export const MINIMAX_TTS_RATE = 24000;

const MAX_WAV_BYTES = 8 * 1024 * 1024;
const ENDPOINT_SILENCE_MS = 700;
const MIN_ENDPOINT_BYTES = 12800;
const SPEECH_START_BYTES = 6400;
const TTS_TIMEOUT_MS = 25000;

function trim(value) {
  return String(value || "").trim();
}

function hostOf(env) {
  return trim(env.MINIMAX_API_HOST).replace(/^https?:\/\//, "").replace(/\/+$/, "") || MINIMAX_API_HOST;
}

export function minimaxSpeechFromEnv(env = process.env) {
  const apiKey = trim(env.MINIMAX_API_KEY);
  if (!apiKey) return null;
  const host = hostOf(env);
  return {
    enabled: true,
    apiKey,
    asrUrl: trim(env.MINIMAX_ASR_URL) || `https://${host}/v1/speech_to_text`,
    ttsUrl: trim(env.MINIMAX_TTS_WS_URL) || `wss://${host}/ws/v1/t2a_v2_bidi`,
    ttsModel: trim(env.MINIMAX_TTS_MODEL) || MINIMAX_TTS_MODEL,
    asrModel: trim(env.MINIMAX_ASR_MODEL) || MINIMAX_ASR_MODEL,
    ttsVoice: DEFAULT_MINIMAX_TTS_VOICE,
    asrLanguage: "zh",
    inputRate: 16000,
    outputRate: MINIMAX_TTS_RATE,
  };
}

function voiceIdOf(minimax) {
  return isMinimaxTtsVoice(minimax?.ttsVoice) ? minimax.ttsVoice : DEFAULT_MINIMAX_TTS_VOICE;
}

function parseMessage(raw) {
  try {
    const text = Buffer.isBuffer(raw) ? raw.toString("utf8") : String(raw ?? "");
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
}

function failureOf(msg) {
  if (!msg) return null;
  const code = Number(msg?.base_resp?.status_code || 0);
  if (code) {
    const err = new Error(msg.base_resp?.status_msg || `minimax speech failed (${code})`);
    err.status = code >= 400 && code < 600 ? code : 502;
    return err;
  }
  if (msg.event === "task_failed" || msg.event === "error") {
    const err = new Error(msg.base_resp?.status_msg || msg.message || "minimax speech failed");
    err.status = 502;
    return err;
  }
  return null;
}

function openSocket(url, apiKey, connectImpl) {
  if (connectImpl) return Promise.resolve(connectImpl(url, apiKey));
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, { headers: { Authorization: `Bearer ${apiKey}` } });
    const fail = (err) => {
      ws.removeListener("open", ok);
      reject(err instanceof Error ? err : new Error("minimax tts connect failed"));
    };
    const ok = () => {
      ws.removeListener("error", fail);
      resolve(ws);
    };
    ws.once("open", ok);
    ws.once("error", fail);
  });
}

/**
 * Official bidirectional TTS: one sentence goes in via task_continue, PCM
 * chunks come back on task_continued, and task_flush pushes a short tail
 * that has no sentence punctuation.
 */
export async function minimaxTtsStream(minimax, text, { signal, onPcm, connectImpl } = {}) {
  const spoken = String(text || "").trim();
  if (!isSpeakableTtsText(spoken)) return 0;
  const socket = await openSocket(minimax.ttsUrl, minimax.apiKey, connectImpl);
  const queue = [];
  let waiter = null;
  let closed = false;
  const push = (msg) => {
    if (waiter) {
      const resume = waiter;
      waiter = null;
      resume(msg);
      return;
    }
    queue.push(msg);
  };
  const onMessage = (raw) => {
    const msg = parseMessage(raw);
    if (msg) push(msg);
  };
  const markClosed = () => {
    if (closed) return;
    closed = true;
    push(null);
  };
  socket.on("message", onMessage);
  socket.on("close", markClosed);
  const deadline = Date.now() + TTS_TIMEOUT_MS;
  const next = () => {
    if (queue.length) return Promise.resolve(queue.shift());
    if (closed || signal?.aborted) return Promise.resolve(null);
    const left = deadline - Date.now();
    if (left <= 0) {
      const err = new Error("minimax tts timeout");
      err.status = 504;
      throw err;
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        waiter = null;
        const err = new Error("minimax tts timeout");
        err.status = 504;
        reject(err);
      }, left);
      waiter = (msg) => {
        clearTimeout(timer);
        resolve(msg);
      };
    });
  };
  const onAbort = () => {
    try {
      socket.send(JSON.stringify({ event: "task_cancel" }));
    } catch {
      /* closing */
    }
    markClosed();
  };
  if (signal?.aborted) onAbort();
  else signal?.addEventListener?.("abort", onAbort, { once: true });

  try {
    const hello = await next();
    const helloErr = failureOf(hello);
    if (helloErr) throw helloErr;
    if (!hello) {
      if (signal?.aborted) return 0;
      const err = new Error("minimax tts connect failed");
      err.status = 502;
      throw err;
    }
    if (hello.event !== "connected_success") {
      const err = new Error("minimax tts connect failed");
      err.status = 502;
      throw err;
    }
    socket.send(
      JSON.stringify({
        event: "task_start",
        model: minimax.ttsModel || MINIMAX_TTS_MODEL,
        language_boost: "Chinese",
        voice_setting: {
          voice_id: voiceIdOf(minimax),
          speed: 1,
          vol: 1,
          pitch: 0,
        },
        audio_setting: {
          sample_rate: MINIMAX_TTS_RATE,
          format: "pcm",
          channel: 1,
        },
      }),
    );
    const started = await next();
    const startedErr = failureOf(started);
    if (startedErr) throw startedErr;
    if (!started) {
      if (signal?.aborted) return 0;
      const err = new Error("minimax tts start failed");
      err.status = 502;
      throw err;
    }
    if (started.event !== "task_started") {
      const err = new Error("minimax tts start failed");
      err.status = 502;
      throw err;
    }
    socket.send(JSON.stringify({ event: "task_continue", text: spoken }));
    socket.send(JSON.stringify({ event: "task_flush" }));
    let total = 0;
    let odd = null;
    while (!signal?.aborted) {
      const msg = await next();
      if (!msg) break;
      const err = failureOf(msg);
      if (err) throw err;
      const hex = msg.event === "task_continued" ? String(msg.data?.audio || "") : "";
      if (hex) {
        let pcm = Buffer.from(hex, "hex");
        if (odd) {
          pcm = Buffer.concat([odd, pcm]);
          odd = null;
        }
        if (pcm.length % 2) {
          odd = pcm.subarray(pcm.length - 1);
          pcm = pcm.subarray(0, pcm.length - 1);
        }
        if (pcm.length) {
          total += pcm.length;
          await onPcm?.(pcm);
        }
      }
      if (msg.event === "task_flushed" || msg.event === "task_finished") break;
    }
    if (!signal?.aborted) {
      try {
        socket.send(JSON.stringify({ event: "task_finish" }));
      } catch {
        /* socket already closing */
      }
    }
    if (!total && !signal?.aborted) {
      const err = new Error("minimax tts empty");
      err.status = 502;
      throw err;
    }
    return total;
  } finally {
    signal?.removeEventListener?.("abort", onAbort);
    socket.off?.("message", onMessage);
    socket.off?.("close", markClosed);
    try {
      socket.close();
    } catch {
      /* already gone */
    }
  }
}

export async function minimaxTts(minimax, text, signal, connectImpl) {
  const parts = [];
  await minimaxTtsStream(minimax, text, {
    signal,
    connectImpl,
    onPcm: async (pcm) => {
      parts.push(pcm);
    },
  });
  return parts.length ? Buffer.concat(parts) : Buffer.alloc(0);
}

async function readAsrEvents(res, onDelta) {
  if (!res.body) {
    const raw = typeof res.text === "function" ? await res.text() : "";
    const json = raw ? JSON.parse(raw) : {};
    const text = String(json.text || "").trim();
    if (text) onDelta?.("", text);
    return text;
  }
  const decoder = new TextDecoder();
  let pending = "";
  let text = "";
  const take = (line) => {
    const data = line.startsWith("data:") ? line.slice(5).trim() : "";
    if (!data || data === "[DONE]") return false;
    let event;
    try {
      event = JSON.parse(data);
    } catch {
      return false;
    }
    if (event.delta) text += event.delta;
    onDelta?.(event.delta || "", text);
    return event.finish === true;
  };
  for await (const chunk of res.body) {
    pending += decoder.decode(chunk, { stream: true });
    let idx;
    while ((idx = pending.indexOf("\n")) >= 0) {
      if (take(pending.slice(0, idx).trim())) return text.trim();
      pending = pending.slice(idx + 1);
    }
  }
  if (pending.trim()) take(pending.trim());
  return text.trim();
}

/** Official ASR stream: one complete audio file in, incremental text out over SSE. */
export async function minimaxAsrTranscribe(minimax, pcm, { sampleRate = 16000, signal, onDelta, fetchImpl = fetch } = {}) {
  const audio = Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm || []);
  if (!audio.length) return "";
  const wav = pcm16ToWav(audio, sampleRate);
  if (wav.length > MAX_WAV_BYTES) {
    const err = new Error("录音太长");
    err.status = 413;
    throw err;
  }
  const form = new FormData();
  form.append("model", minimax?.asrModel || MINIMAX_ASR_MODEL);
  form.append("stream", "true");
  form.append("file", new Blob([wav], { type: "audio/wav" }), "utterance.wav");
  const res = await fetchImpl(minimax.asrUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${minimax.apiKey}`,
      language: minimax?.asrLanguage || "zh",
    },
    body: form,
    signal,
  });
  if (!res.ok) {
    const err = new Error(
      res.status === 401 || res.status === 403 ? "minimax asr unauthorized" : `minimax asr failed (${res.status})`,
    );
    err.status = res.status;
    throw err;
  }
  return readAsrEvents(res, onDelta);
}

export function createMinimaxAsr({
  minimax,
  pushToTalk = false,
  onPartial,
  onFinal,
  onError,
  onSpeechStart,
  endpointSilenceMs = ENDPOINT_SILENCE_MS,
  minEndpointBytes = MIN_ENDPOINT_BYTES,
  fetchImpl = fetch,
} = {}) {
  const chunks = [];
  let started = false;
  let chain = Promise.resolve();
  let generation = 0;

  function transcribe(buf) {
    const ticket = generation;
    chain = chain
      .then(async () => {
        if (ticket !== generation) return;
        if (!buf?.length) {
          onFinal?.("");
          return;
        }
        const text = await minimaxAsrTranscribe(minimax, buf, {
          sampleRate: minimax?.inputRate || 16000,
          fetchImpl,
          onDelta: (_delta, soFar) => {
            if (ticket !== generation) return;
            if (soFar) onPartial?.(soFar);
          },
        });
        if (ticket !== generation) return;
        onFinal?.(text);
      })
      .catch((err) => {
        onError?.({ message: String(err.message || err) });
      });
    return chain;
  }

  const gate = createUtteranceGate({
    endpointSilenceMs,
    minEndpointBytes,
    speechStartBytes: SPEECH_START_BYTES,
    armHangMs: 1100,
    onSpeechStart,
    onEndpoint: (buf) => {
      if (!started) return;
      transcribe(buf);
    },
  });

  return {
    speechFloorRms: CALL_MIN_RMS,
    async start() {
      started = true;
      chain = Promise.resolve();
      chunks.length = 0;
      gate.reset();
    },
    push(pcm) {
      if (!started || !pcm) return;
      const buf = Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm);
      if (!buf.length) return;
      if (pushToTalk) {
        chunks.push(buf);
        return;
      }
      gate.push(buf);
    },
    discard() {
      generation += 1;
      chunks.length = 0;
      gate.reset();
    },
    stop() {
      started = false;
      chunks.length = 0;
      gate.reset();
    },
    async finalize() {
      started = false;
      if (pushToTalk) {
        const buf = chunks.length ? Buffer.concat(chunks) : Buffer.alloc(0);
        chunks.length = 0;
        await transcribe(buf);
        return;
      }
      await transcribe(gate.flush());
    },
  };
}
