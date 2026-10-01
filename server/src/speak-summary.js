import { claudeCodeCurrentModel, readClaudeUserSettings } from "./acp.js";
import { isCancelled, requestSignal } from "./http-signal.js";
import { noteServerLog } from "./server-logs.js";
import { openSse, writeSse } from "./sse.js";
import {
  isSpeakableTtsText,
  speechTextFromMarkdown,
  speakTextInParts,
  writeAudioToSse,
} from "./spoken-tts.js";
import { resolveTurnTtsVoice, resolveVoiceConfig, withTtsVoice } from "./voice-config.js";
import { createVoiceProviders } from "./voice-ws.js";

const MAX_SOURCE_CHARS = 4000;

export const DIAGRAM_ONLY_SPOKEN = "这段主要是图或代码，没有适合朗读的正文。";

/** Prose worth summarizing. Fences and markup are already stripped. */
export function clipAnswerForSpeech(text, maxChars = MAX_SOURCE_CHARS) {
  const cleaned = speechTextFromMarkdown(text).replace(/\n{3,}/g, "\n\n").trim();
  const chars = [...cleaned];
  if (chars.length <= maxChars) return cleaned;
  return `${chars.slice(0, maxChars).join("")}……`;
}

export function buildSpeakSummaryPrompt(text) {
  return [
    "你只改写下面这段回答，让它适合朗读。不要查文件，不要改任何文件，不要调用工具。",
    "只输出要念出来的口语正文：先说结论，一般两三句，最多五句。",
    "不要 Markdown、列表、表格、代码、链接、路径，也不要以「好的」「总结一下」「简单来说」开头。",
    "",
    "=== 原文 ===",
    text,
  ].join("\n");
}

function tidySpoken(text) {
  return speechTextFromMarkdown(text).replace(/[ \t]+\n/g, "\n").trim();
}

/**
 * Rewrite [text] into a short spoken summary, then synthesize it.
 * [prompt] is `(promptText, { onDelta, signal }) => Promise`.
 */
export async function runSpeakSummary({
  text,
  prompt,
  tts,
  onPhase,
  onCaption,
  onAudio,
  signal,
}) {
  const source = clipAnswerForSpeech(text);
  onPhase?.("think");
  let spoken = DIAGRAM_ONLY_SPOKEN;
  if (source) {
    let full = "";
    await prompt(buildSpeakSummaryPrompt(source), {
      signal,
      onDelta: (chunk) => {
        full += String(chunk || "");
      },
    });
    if (signal?.aborted) return "";
    spoken = tidySpoken(full);
  }
  if (!isSpeakableTtsText(spoken)) {
    const err = new Error("没有可朗读的内容");
    err.code = "empty_answer";
    throw err;
  }
  onPhase?.("speak");
  await speakTextInParts({ text: spoken, tts, onCaption, onAudio, signal });
  return spoken;
}

function fileEnv(settings) {
  return settings?.env && typeof settings.env === "object" ? settings.env : {};
}

/**
 * Claude Code's current model and Anthropic-compatible endpoint.
 * Explicit settings win. When settings are omitted, fall back to the process env.
 */
export function speakSummaryApiConfig(settings, env = process.env) {
  const file = settings === undefined ? readClaudeUserSettings() : settings;
  const fromFile = fileEnv(file);
  const pick = (key) => {
    const saved = String(fromFile[key] || "").trim();
    if (saved) return saved;
    if (settings !== undefined) return "";
    return String(env?.[key] || "").trim();
  };
  const token = pick("ANTHROPIC_AUTH_TOKEN") || pick("ANTHROPIC_API_KEY");
  const base = pick("ANTHROPIC_BASE_URL").replace(/\/+$/, "");
  const model = claudeCodeCurrentModel(file || {});
  if (!token || !base || !model) return null;
  return {
    model,
    base,
    token,
    auth: pick("ANTHROPIC_AUTH_TOKEN") ? "bearer" : "api-key",
  };
}

export function speakSummaryMessagesUrl(base) {
  const trimmed = String(base || "").replace(/\/+$/, "");
  if (/\/v1$/i.test(trimmed)) return `${trimmed}/messages`;
  return `${trimmed}/v1/messages`;
}

/** Assistant prose only. Thinking blocks are not spoken. */
export function textFromMessagesResponse(json) {
  const content = json?.content;
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .filter((part) => part && part.type !== "thinking" && part.type !== "reasoning" && part.text)
      .map((part) => part.text)
      .join("");
  }
  const choice = json?.choices?.[0]?.message?.content;
  return typeof choice === "string" ? choice : "";
}

/**
 * One non-streaming messages call. No tools, no agent session.
 * [config] is the result of [speakSummaryApiConfig].
 */
export async function completeSpeakSummary(
  promptText,
  { config, signal, onDelta, fetchImpl = fetch, timeoutMs = 20_000 } = {},
) {
  const ctrl = new AbortController();
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    ctrl.abort();
  }, timeoutMs);
  const onAbort = () => ctrl.abort();
  if (signal?.aborted) ctrl.abort();
  else signal?.addEventListener?.("abort", onAbort, { once: true });
  try {
    const headers = {
      "content-type": "application/json",
      "anthropic-version": "2023-06-01",
    };
    if (config.auth === "bearer") {
      headers.authorization = `Bearer ${config.token}`;
      headers["x-api-key"] = config.token;
    } else {
      headers["x-api-key"] = config.token;
    }
    const res = await fetchImpl(speakSummaryMessagesUrl(config.base), {
      method: "POST",
      headers,
      body: JSON.stringify({
        model: config.model,
        max_tokens: 300,
        messages: [{ role: "user", content: promptText }],
      }),
      signal: ctrl.signal,
    });
    const raw = await res.text();
    clearTimeout(timer);
    timedOut = false;
    let json = null;
    try {
      json = raw ? JSON.parse(raw) : null;
    } catch {
      json = null;
    }
    const providerCode = Number(json?.base_resp?.status_code);
    const providerError = json?.type === "error" || (json?.error && !json?.content);
    if (!res.ok || providerError || (Number.isFinite(providerCode) && providerCode !== 0)) {
      const err = new Error(`模型接口失败 (${res.status})`);
      err.status = res.status;
      const kind = String(json?.error?.type || "");
      err.code =
        res.status === 401 || res.status === 403 || /auth/i.test(kind) ? "model_auth" : "model_failed";
      throw err;
    }
    const text = textFromMessagesResponse(json).trim();
    if (!text) {
      const err = new Error("模型没有返回可朗读的话");
      err.code = "empty_answer";
      throw err;
    }
    onDelta?.(text);
    return text;
  } catch (err) {
    if (signal?.aborted) throw err;
    if (timedOut) {
      const timeout = new Error("模型接口超时");
      timeout.code = "model_timeout";
      throw timeout;
    }
    throw err;
  } finally {
    clearTimeout(timer);
    signal?.removeEventListener?.("abort", onAbort);
  }
}

export async function handleSpeakSummary(
  req,
  res,
  {
    store,
    resolveConfig = resolveVoiceConfig,
    createProviders = createVoiceProviders,
    resolveApi = speakSummaryApiConfig,
    complete = completeSpeakSummary,
    signalOf = requestSignal,
  } = {},
) {
  const text = String(req.body?.text || "").trim();
  if (!text) {
    res.status(400).json({ error: "text is required" });
    return;
  }

  const baseVoiceConfig = resolveConfig();
  const voiceConfig = withTtsVoice(
    baseVoiceConfig,
    resolveTurnTtsVoice(req.body?.ttsVoice, store?.config?.ttsVoice, baseVoiceConfig),
  );
  const providers = createProviders(voiceConfig);
  if (!voiceConfig.ready || !providers.tts) {
    res.status(503).json({
      error: "语音未配置",
      code: "unconfigured",
      hint: voiceConfig.hint || "还没配语音密钥",
    });
    return;
  }

  const source = clipAnswerForSpeech(text);
  const api = source ? resolveApi() : null;
  if (source && !api) {
    res.status(503).json({
      error: "口语总结直接调用 Claude Code 当前模型。请在 Claude Code 设置里配好接口地址和密钥。",
      code: "model_unconfigured",
    });
    return;
  }

  const signal = signalOf(req, res);
  openSse(res);
  writeSse(res, { type: "state", phase: "think" });

  try {
    if (signal.aborted) return;

    const spoken = await runSpeakSummary({
      text,
      prompt: (promptText, opts) => complete(promptText, { ...opts, config: api }),
      tts: (piece, ttsSignal) => providers.tts(piece, ttsSignal || signal),
      onPhase: (phase) => {
        if (!signal.aborted) writeSse(res, { type: "state", phase });
      },
      onCaption: (caption) => {
        if (!signal.aborted && String(caption || "").trim()) {
          writeSse(res, { type: "caption", text: String(caption) });
        }
      },
      onAudio: async (buf) => {
        if (signal.aborted || !buf?.length) return;
        writeAudioToSse(res, (r, ev) => writeSse(r, { type: "audio", ...ev }), buf, voiceConfig, signal);
      },
      signal,
    });
    if (!signal.aborted) {
      writeSse(res, { type: "done", answer: spoken, engine: "api" });
    }
  } catch (err) {
    if (signal.aborted || isCancelled(err)) return;
    let hint = "没能朗读这段回答，请稍后再试。";
    let code = err.code || "speak_failed";
    if (code === "empty_answer") {
      hint = "没有可朗读的内容。";
    } else if (code === "model_auth") {
      hint = "模型接口没有通过校验，请检查 Claude Code 里的密钥。";
    } else if (code === "model_timeout") {
      hint = "模型接口超时，请再试一次。";
    } else if (code === "model_failed") {
      hint = "模型接口暂时不可用，请稍后再试。";
    } else if (/tts/i.test(String(err.message || "")) || err.status === 401 || err.status === 403) {
      code = "tts_failed";
      hint = "语音合成失败，请检查本机的语音配置。";
    }
    noteServerLog({
      kind: code === "tts_failed" ? "voice-tts" : "voice-turn",
      message: String(err?.message || err),
      summary: hint,
    });
    writeSse(res, { type: "error", code, hint });
  } finally {
    res.end();
  }
}
