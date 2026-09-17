import { randomUUID } from "node:crypto";
import { gunzipSync, gzipSync } from "node:zlib";
import { WebSocket } from "ws";

export function volcHeader({ type, flags = 0, serialization = 0, compression = 0 }) {
  const buf = Buffer.alloc(4);
  buf[0] = 0x11;
  buf[1] = ((type & 0x0f) << 4) | (flags & 0x0f);
  buf[2] = ((serialization & 0x0f) << 4) | (compression & 0x0f);
  buf[3] = 0;
  return buf;
}

export function encodeVolcClientRequest(payload) {
  const compressed = gzipSync(Buffer.from(JSON.stringify(payload)));
  const size = Buffer.alloc(4);
  size.writeUInt32BE(compressed.length);
  return Buffer.concat([volcHeader({ type: 1, flags: 0, serialization: 1, compression: 1 }), size, compressed]);
}

export function encodeVolcAudio(pcm, { last = false } = {}) {
  const compressed = gzipSync(Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm));
  const size = Buffer.alloc(4);
  size.writeUInt32BE(compressed.length);
  return Buffer.concat([
    volcHeader({ type: 2, flags: last ? 2 : 0, serialization: 0, compression: 1 }),
    size,
    compressed,
  ]);
}

export function decodeVolcServerFrame(raw) {
  const buf = Buffer.isBuffer(raw) ? raw : Buffer.from(raw);
  if (buf.length < 4) return { type: "empty" };
  const type = (buf[1] >> 4) & 0x0f;
  const flags = buf[1] & 0x0f;
  const serialization = (buf[2] >> 4) & 0x0f;
  const compression = buf[2] & 0x0f;
  let offset = 4;
  let sequence;
  if (flags & 0x01 || flags & 0x03) {
    if (buf.length >= offset + 4) {
      sequence = buf.readInt32BE(offset);
      offset += 4;
    }
  }
  if (type === 0x0f) {
    const code = buf.length >= offset + 4 ? buf.readUInt32BE(offset) : 0;
    offset += 4;
    const size = buf.length >= offset + 4 ? buf.readUInt32BE(offset) : 0;
    offset += 4;
    const message = buf.subarray(offset, offset + size).toString("utf8");
    return { type: "error", code, message, sequence };
  }
  const size = buf.length >= offset + 4 ? buf.readUInt32BE(offset) : 0;
  offset += 4;
  let payload = buf.subarray(offset, offset + size);
  if (compression === 1 && payload.length) {
    try {
      payload = gunzipSync(payload);
    } catch {
      /* keep raw */
    }
  }
  let json = null;
  if (serialization === 1 && payload.length) {
    try {
      json = JSON.parse(payload.toString("utf8"));
    } catch {
      json = null;
    }
  }
  return { type: type === 9 ? "result" : "frame", flags, sequence, json, payload };
}

export function extractAsrText(json) {
  const result = json?.result;
  if (!result) return { text: "", definite: false };
  if (typeof result === "string") return { text: result, definite: false };
  if (Array.isArray(result)) {
    const last = result[result.length - 1] || {};
    return { text: String(last.text || ""), definite: Boolean(last.definite) };
  }
  const utterances = Array.isArray(result.utterances) ? result.utterances : [];
  const lastUtt = utterances[utterances.length - 1];
  return {
    text: String(result.text || lastUtt?.text || ""),
    definite: Boolean(lastUtt?.definite),
  };
}

export function defaultAsrConfigPayload() {
  return {
    user: { uid: "wenxiang" },
    audio: { format: "pcm", rate: 16000, bits: 16, channel: 1, language: "zh-CN", codec: "raw" },
    request: {
      model_name: "bigmodel",
      enable_itn: true,
      enable_punc: true,
      enable_ddc: true,
      result_type: "single",
      show_utterances: true,
      end_window_size: 700,
    },
  };
}

export function volcAsrHeaders(volc) {
  const headers = {
    "X-Api-Resource-Id": volc.asrResourceId || "volc.bigasr.sauc.duration",
    "X-Api-Connect-Id": randomUUID(),
    "X-Api-Request-Id": randomUUID(),
  };
  if (volc.apiKey) headers["X-Api-Key"] = volc.apiKey;
  if (volc.appId) headers["X-Api-App-Key"] = volc.appId;
  if (volc.accessToken) headers["X-Api-Access-Key"] = volc.accessToken;
  return headers;
}

export function createVolcAsr({
  volc,
  connect = (url, options) => new WebSocket(url, options),
  onPartial,
  onFinal,
  onError,
} = {}) {
  let socket = null;
  let opened = false;
  const pending = [];

  function flush() {
    if (!opened || !socket || socket.readyState !== 1) return;
    while (pending.length) socket.send(pending.shift());
  }

  return {
    async start() {
      socket = connect(volc.asrUrl, { headers: volcAsrHeaders(volc) });
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("asr timeout")), 8000);
        socket.once("open", () => {
          clearTimeout(timer);
          opened = true;
          socket.send(encodeVolcClientRequest(defaultAsrConfigPayload()));
          flush();
          resolve();
        });
        socket.once("error", (err) => {
          clearTimeout(timer);
          reject(err);
        });
      });
      socket.on("message", (data) => {
        const frame = decodeVolcServerFrame(data);
        if (frame.type === "error") {
          onError?.({ message: frame.message, code: frame.code });
          return;
        }
        if (frame.type !== "result" || !frame.json) return;
        const extracted = extractAsrText(frame.json);
        if (!extracted.text) return;
        if (extracted.definite) onFinal?.(extracted.text);
        else onPartial?.(extracted.text);
      });
    },
    push(pcm) {
      pending.push(encodeVolcAudio(pcm));
      flush();
    },
    stop() {
      if (socket && opened) {
        try {
          socket.send(encodeVolcAudio(Buffer.alloc(0), { last: true }));
        } catch {
          /* ignore */
        }
      }
      opened = false;
      socket?.close();
      socket = null;
    },
  };
}

export async function volcTts(volc, text, signal, fetchImpl = fetch) {
  const spoken = String(text || "").trim();
  if (!spoken) return Buffer.alloc(0);
  const body = {
    app: {
      appid: volc.appId || "",
      token: volc.accessToken || volc.apiKey || "",
      cluster: volc.ttsCluster || "volcano_tts",
    },
    user: { uid: "wenxiang" },
    audio: {
      voice_type: volc.ttsVoice || "zh_female_vv_uranus_bigtts",
      encoding: "pcm",
      rate: 24000,
      speed_ratio: 1.05,
    },
    request: {
      reqid: randomUUID(),
      text: spoken,
      text_type: "plain",
      operation: "query",
    },
  };
  const res = await fetchImpl(volc.ttsUrl, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok) {
    const err = new Error("tts failed");
    err.status = res.status;
    throw err;
  }
  const json = await res.json();
  if (!json?.data) return Buffer.alloc(0);
  return Buffer.from(json.data, "base64");
}
