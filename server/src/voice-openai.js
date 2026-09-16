import { WebSocket } from "ws";

export function openAiRealtimeHeaders(openai) {
  return {
    Authorization: `Bearer ${openai.apiKey}`,
    "OpenAI-Beta": "realtime=v1",
  };
}

export function createOpenAiAsr({
  openai,
  connect = (url, options) => new WebSocket(url, options),
  onPartial,
  onFinal,
  onSpeechStart,
} = {}) {
  let socket = null;
  let opened = false;
  const pending = [];
  const url = `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(openai.realtimeModel || "gpt-4o-realtime-preview")}`;

  function send(obj) {
    const payload = JSON.stringify(obj);
    if (!opened || !socket || socket.readyState !== 1) {
      pending.push(payload);
      return;
    }
    socket.send(payload);
  }

  function flush() {
    if (!opened || !socket || socket.readyState !== 1) return;
    while (pending.length) socket.send(pending.shift());
  }

  return {
    async start() {
      socket = connect(url, { headers: openAiRealtimeHeaders(openai) });
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error("asr timeout")), 8000);
        socket.once("open", () => {
          clearTimeout(timer);
          opened = true;
          send({
            type: "session.update",
            session: {
              modalities: ["text", "audio"],
              input_audio_format: "pcm16",
              output_audio_format: "pcm16",
              input_audio_transcription: { model: "whisper-1" },
              turn_detection: {
                type: "server_vad",
                threshold: 0.5,
                prefix_padding_ms: 200,
                silence_duration_ms: 500,
                create_response: false,
              },
            },
          });
          flush();
          resolve();
        });
        socket.once("error", (err) => {
          clearTimeout(timer);
          reject(err);
        });
      });
      socket.on("message", (data) => {
        let msg;
        try {
          msg = JSON.parse(data.toString());
        } catch {
          return;
        }
        if (msg.type === "input_audio_buffer.speech_started") onSpeechStart?.();
        if (msg.type === "conversation.item.input_audio_transcription.delta" && msg.delta) {
          onPartial?.(msg.delta);
        }
        if (msg.type === "conversation.item.input_audio_transcription.completed" && msg.transcript) {
          onFinal?.(msg.transcript);
        }
      });
    },
    push(pcm) {
      const buf = Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm);
      if (!buf.length) return;
      send({ type: "input_audio_buffer.append", audio: buf.toString("base64") });
    },
    stop() {
      opened = false;
      socket?.close();
      socket = null;
    },
  };
}

export async function openAiTts(openai, text, signal, fetchImpl = fetch) {
  const spoken = String(text || "").trim();
  if (!spoken) return Buffer.alloc(0);
  const res = await fetchImpl("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${openai.apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: openai.ttsModel || "gpt-4o-mini-tts",
      voice: openai.ttsVoice || "alloy",
      input: spoken,
      response_format: "pcm",
    }),
    signal,
  });
  if (!res.ok) {
    const err = new Error("tts failed");
    err.status = res.status;
    throw err;
  }
  return Buffer.from(await res.arrayBuffer());
}
