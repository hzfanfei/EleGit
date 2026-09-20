import { WebSocketServer } from "ws";
import { formatProgressContext } from "./github.js";
import { streamAnswer } from "./ask.js";
import { publicVoiceStatus, resolveVoiceConfig } from "./voice-config.js";
import { createVoiceSession } from "./voice-session.js";
import { createOpenAiAsr, openAiTts } from "./voice-openai.js";
import { cosyvoiceTts } from "./cosyvoice-tts.js";
import { createFunasrAsr } from "./funasr-asr.js";
import { createVolcAsr, volcTts } from "./voice-volc.js";
import { formatLocalContext } from "./workspace.js";

export function voiceKeyFromRequest(req) {
  const header = String(req.headers?.["x-wenxiang-key"] || "").trim();
  if (header) return header;
  try {
    const url = new URL(req.url || "", "http://127.0.0.1");
    return String(url.searchParams.get("key") || "").trim();
  } catch {
    return "";
  }
}

export function isVoiceUpgrade(req) {
  try {
    const url = new URL(req.url || "", "http://127.0.0.1");
    return url.pathname === "/v1/voice";
  } catch {
    return false;
  }
}

export function isVoiceCallEnabled(env = process.env) {
  return String(env.WENXIANG_VOICE_CALL_ENABLED || "").trim().toLowerCase() === "true";
}

export function createDefaultAsk() {
  return async function* (opts, signal) {
    const checkout = opts.checkout || {};
    const progress = checkout.progress || { repo: { fullName: `${opts.owner}/${opts.repo}` }, commits: [], pulls: [], issues: [] };
    const local = checkout.local || {};
    const githubContext = formatProgressContext(progress);
    const context = `${githubContext}\n\n${formatLocalContext(local)}`;
    yield* streamAnswer({
      question: opts.question,
      history: opts.history,
      progress,
      context,
      githubContext,
      local,
      session: opts.session,
      sessions: opts.sessions,
      signal,
    });
  };
}

function resolveAsr(config, hooks) {
  if (config?.asrProvider === "funasr" && config.funasr?.enabled) {
    return createFunasrAsr({
      funasr: config.funasr,
      pushToTalk: hooks.pushToTalk === true,
      onPartial: hooks.onPartial,
      onFinal: hooks.onFinal,
      onError: (detail) => hooks.onAsrError?.({ message: detail?.message, err: detail }),
    });
  }
  if (config?.provider === "volc" && config.volc) {
    return createVolcAsr({
      volc: config.volc,
      onPartial: hooks.onPartial,
      onFinal: hooks.onFinal,
      onError: (detail) => hooks.onAsrError?.({ message: detail?.message, err: detail }),
    });
  }
  if (config?.provider === "openai" && config.openai) {
    return createOpenAiAsr({
      openai: config.openai,
      pushToTalk: hooks.pushToTalk === true,
      onPartial: hooks.onPartial,
      onFinal: hooks.onFinal,
      onSpeechStart: hooks.onSpeechStart,
    });
  }
  return null;
}

function resolveTtsFn(config) {
  if (config?.ttsProvider === "cosyvoice" && config.cosyvoice?.enabled) {
    return (text, signal) => cosyvoiceTts(config.cosyvoice, text, signal);
  }
  if (config?.provider === "volc" && config.volc) {
    return (text, signal) => volcTts(config.volc, text, signal);
  }
  if (config?.provider === "openai" && config.openai) {
    return (text, signal) => openAiTts(config.openai, text, signal);
  }
  return null;
}

export function createVoiceProviders(config, hooks = {}) {
  if (config?.ready && (config.provider === "volc" || config.provider === "openai")) {
    return {
      asr: resolveAsr(config, hooks),
      tts: resolveTtsFn(config),
    };
  }
  return { asr: null, tts: null };
}

export function attachVoiceGateway(httpServer, {
  getApiKey,
  checkoutRepo,
  sessions,
  resolveConfig = resolveVoiceConfig,
  createAsk = createDefaultAsk,
  createProviders = createVoiceProviders,
} = {}) {
  const wss = new WebSocketServer({ noServer: true });

  httpServer.on("close", () => {
    wss.close();
  });

  httpServer.on("upgrade", (req, socket, head) => {
    if (!isVoiceUpgrade(req)) return;
    if (!isVoiceCallEnabled()) {
      socket.write("HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n");
      socket.destroy();
      return;
    }
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
    const ask = createAsk();
    const holder = { session: null };
    const providers = createProviders(config, {
      onPartial: (text) => holder.session?.onTranscript(text, { final: false }),
      onFinal: (text) => holder.session?.onTranscript(text, { final: true }),
      onSpeechStart: () => holder.session?.barge(),
    });
    const session = createVoiceSession({
      config,
      send: (msg) => {
        if (ws.readyState === 1) ws.send(JSON.stringify(msg));
      },
      sendAudio: (buf) => {
        if (ws.readyState === 1 && buf?.length) ws.send(buf);
      },
      checkout: checkoutRepo,
      sessions,
      ask,
      tts: providers.tts,
      asr: providers.asr,
    });
    holder.session = session;

    if (!config.ready) {
      ws.send(JSON.stringify({ type: "error", code: "unconfigured", hint: config.hint || "还没配语音密钥" }));
    }

    ws.on("message", (data, isBinary) => {
      if (isBinary || Buffer.isBuffer(data) && data[0] !== 0x7b) {
        session.onPcm(data);
        return;
      }
      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        return;
      }
      if (msg.type === "hello") session.start(msg);
      else if (msg.type === "barge") session.barge();
      else if (msg.type === "hangup") {
        session.hangup();
        ws.close();
      }
    });
    ws.on("close", () => session.hangup());
  });

  return wss;
}

export { publicVoiceStatus, resolveVoiceConfig };
