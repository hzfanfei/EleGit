import { gzipSync } from "node:zlib";

/** Split long spoken text into TTS-sized pieces (prefer sentence boundaries). */
export function splitTextForTts(text, maxChars = 320) {
  const s = String(text || "").trim();
  if (!s) return [];
  const chars = [...s];
  if (chars.length <= maxChars) return [s];

  const out = [];
  let buf = "";
  const punct = /[。！？!?；;\n]/;
  for (const ch of chars) {
    buf += ch;
    const len = [...buf].length;
    if (punct.test(ch) && len >= 24) {
      out.push(buf.trim());
      buf = "";
    } else if (len >= maxChars) {
      out.push(buf.trim());
      buf = "";
    }
  }
  if (buf.trim()) out.push(buf.trim());
  return out.filter(Boolean);
}

export async function speakTextInParts({ text, tts, onCaption, onAudio, signal }) {
  const parts = splitTextForTts(text);
  for (const part of parts) {
    if (signal?.aborted) break;
    onCaption?.(part);
    const audio = await tts(part, signal);
    if (signal?.aborted) break;
    if (audio?.length) await onAudio(audio);
  }
}

/** Build one SSE audio payload (PCM gzip or MP3). */
export function buildAudioSsePayload(
  buf,
  { format = "pcm", codec = "gzip", rate = 24000 } = {},
) {
  const raw = Buffer.isBuffer(buf) ? buf : Buffer.from(buf || []);
  if (format === "mp3") {
    return {
      format: "mp3",
      rate,
      audio: raw.toString("base64"),
    };
  }
  let payload = raw;
  let outCodec = "raw";
  if (codec === "gzip" && raw.length > 0) {
    payload = gzipSync(raw, { level: 6 });
    outCodec = "gzip";
  }
  return {
    format: "pcm",
    codec: outCodec,
    rate,
    pcm: payload.toString("base64"),
  };
}

/** Keep SSE / client JSON small — chunk raw PCM for streaming playback. */
export function forEachPcmChunk(pcm, chunkBytes = 48 * 1024, fn) {
  const buf = Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm || []);
  for (let i = 0; i < buf.length; i += chunkBytes) {
    fn(buf.subarray(i, Math.min(i + chunkBytes, buf.length)));
  }
}

export function writeAudioToSse(res, writeSse, buf, voiceConfig, signal) {
  const format =
    voiceConfig?.provider === "volc" && voiceConfig.volc?.ttsFormat !== "pcm"
      ? voiceConfig.volc?.ttsFormat || "mp3"
      : "pcm";
  const isPcm = format === "pcm";
  const emit = (slice) => {
    if (signal?.aborted) return;
    writeSse(
      res,
      buildAudioSsePayload(slice, {
        format: isPcm ? "pcm" : "mp3",
        codec: "raw",
        rate: 24000,
      }),
    );
  };
  if (isPcm) {
    const maxSingle = 900 * 1024;
    if (buf.length <= maxSingle) {
      emit(buf);
    } else {
      forEachPcmChunk(buf, 384 * 1024, emit);
    }
  } else {
    emit(buf);
  }
}
