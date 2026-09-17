import { WebSocketServer } from "ws";
import { resolveVoiceConfig } from "./voice-config.js";
import { createVoiceProviders, voiceKeyFromRequest } from "./voice-ws.js";

export function isSttUpgrade(req) {
  try {
    const url = new URL(req.url || "", "http://127.0.0.1");
    return url.pathname === "/v1/voice/stt";
  } catch {
    return false;
  }
}

export function createSttSession({
  config,
  send,
  createProviders = createVoiceProviders,
} = {}) {
  let asr = null;
  let closed = false;
  let partial = "";
  let finalText = "";
  let stopping = null;

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
      partial = "";
      finalText = "";
      const providers = createProviders(config, {
        onPartial: (text) => {
          partial = String(text || "");
          if (partial) emit({ type: "caption", role: "user", text: partial, final: false });
        },
        onFinal: (text) => {
          finalText = String(text || "");
          if (finalText) emit({ type: "caption", role: "user", text: finalText, final: true });
        },
      });
      asr = providers.asr;
      if (!asr) {
        emit({ type: "error", code: "unconfigured", hint: config.hint || "还没配语音密钥" });
        return;
      }
      await asr.start();
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
        const text = String(finalText || partial || "").trim();
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
