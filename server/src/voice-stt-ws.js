import { WebSocketServer } from "ws";
import { resolveVoiceConfig } from "./voice-config.js";
import { sttErrorFromFailure } from "./voice-stt-copy.js";
import { createVoiceProviders, voiceKeyFromRequest } from "./voice-ws.js";

export function isSttUpgrade(req) {
  try {
    const url = new URL(req.url || "", "http://127.0.0.1");
    return url.pathname === "/v1/voice/stt";
  } catch {
    return false;
  }
}

/** @param {string[]} segments committed finals */
export function composeSttDisplay(segments, partial) {
  const head = segments.join("");
  const tail = String(partial || "");
  if (!head) return tail;
  if (!tail) return head;
  if (tail.startsWith(head)) return tail;
  return head + tail;
}

export function adoptSttFinal(segments, finalChunk) {
  const seg = String(finalChunk || "").trim();
  if (!seg) return;
  const head = segments.join("");
  if (!head) {
    segments.push(seg);
    return;
  }
  if (seg.startsWith(head)) {
    segments.length = 0;
    segments.push(seg);
    return;
  }
  if (head.includes(seg)) return;
  segments.push(seg);
}

export function mergeSttPartial({ segments, partial, incoming, partialMode }) {
  const chunk = String(incoming || "");
  if (!chunk) return partial;
  if (partialMode === "delta") {
    return partial + chunk;
  }
  const head = segments.join("");
  if (!head) return chunk;
  if (chunk.startsWith(head)) return chunk.slice(head.length);
  return chunk;
}

export function createSttSession({
  config,
  send,
  createProviders = createVoiceProviders,
} = {}) {
  let asr = null;
  let closed = false;
  const segments = [];
  let partial = "";
  let stopping = null;
  const partialMode = config?.provider === "openai" ? "delta" : "cumulative";

  function emit(msg) {
    if (closed) return;
    send?.(msg);
  }

  function cleanup() {
    closed = true;
    try {
      asr?.stop?.();
    } catch {
      /* ignore */
    }
    asr = null;
  }

  return {
    async start() {
      if (!config?.ready) {
        emit({ type: "error", code: "unconfigured", hint: config.hint || "还没配语音密钥" });
        return;
      }
      segments.length = 0;
      partial = "";
      const providers = createProviders(config, {
        pushToTalk: true,
        onPartial: (text) => {
          partial = mergeSttPartial({ segments, partial, incoming: text, partialMode });
          const display = composeSttDisplay(segments, partial);
          if (display) emit({ type: "caption", role: "user", text: display, final: false });
        },
        onFinal: (text) => {
          adoptSttFinal(segments, text);
          partial = "";
          const display = composeSttDisplay(segments, partial);
          if (display) emit({ type: "caption", role: "user", text: display, final: true });
        },
        onAsrError: (detail) => {
          const mapped = sttErrorFromFailure(detail?.err, detail?.message);
          emit({ type: "error", code: mapped.code, hint: mapped.hint });
          cleanup();
        },
      });
      asr = providers.asr;
      if (!asr) {
        emit({ type: "error", code: "unconfigured", hint: config.hint || "还没配语音密钥" });
        return;
      }
      try {
        await asr.start();
      } catch (err) {
        const mapped = sttErrorFromFailure(err);
        emit({ type: "error", code: mapped.code, hint: mapped.hint });
        cleanup();
        return;
      }
      emit({ type: "state", state: "listening" });
    },
    onPcm(data) {
      if (closed || !asr) return;
      asr.push(data);
    },
    async stop() {
      if (closed || stopping) return stopping;
      stopping = (async () => {
        if (asr?.finalize) {
          try {
            await asr.finalize();
          } catch {
            /* fall through */
          }
        } else {
          try {
            asr?.stop?.();
          } catch {
            /* ignore */
          }
        }
        await new Promise((resolve) => setTimeout(resolve, 120));
        const text = composeSttDisplay(segments, partial).trim();
        emit({ type: "done", text });
        cleanup();
      })();
      return stopping;
    },
    cancel() {
      if (closed) return;
      cleanup();
      emit({ type: "cancelled" });
    },
    hangup() {
      if (closed) return;
      cleanup();
    },
  };
}

export function attachSttGateway(httpServer, {
  getApiKey,
  resolveConfig = resolveVoiceConfig,
  createProviders = createVoiceProviders,
  createSession = createSttSession,
} = {}) {
  const wss = new WebSocketServer({ noServer: true });

  httpServer.on("close", () => {
    wss.close();
  });

  httpServer.on("upgrade", (req, socket, head) => {
    if (!isSttUpgrade(req)) return;
    const expected = String(getApiKey?.() || "");
    if (!expected || voiceKeyFromRequest(req) !== expected) {
      socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req);
    });
  });

  wss.on("connection", (ws) => {
    const config = resolveConfig();
    const session = createSession({ config, send: (msg) => {
      if (ws.readyState === 1) ws.send(JSON.stringify(msg));
    }, createProviders });

    if (!config.ready) {
      ws.send(JSON.stringify({ type: "error", code: "unconfigured", hint: config.hint || "还没配语音密钥" }));
    }

    ws.on("message", async (data, isBinary) => {
      if (isBinary || (Buffer.isBuffer(data) && data[0] !== 0x7b)) {
        session.onPcm(data);
        return;
      }
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (msg.type === "start") await session.start();
      else if (msg.type === "stop") await session.stop();
      else if (msg.type === "cancel") session.cancel();
      else if (msg.type === "hangup") {
        session.hangup();
        ws.close();
      }
    });
    ws.on("close", () => session.hangup());
  });

  return wss;
}
