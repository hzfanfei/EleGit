import { mkdirSync } from "node:fs";

import { AcpChannel, detectCursorEngine } from "./acp.js";
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

function defaultCreateChannel({ command, cwd }) {
  return new AcpChannel({ command, cwd, idleMs: 2 * 60 * 1000 });
}

export async function handleSpeakSummary(
  req,
  res,
  {
    store,
    resolveConfig = resolveVoiceConfig,
    createProviders = createVoiceProviders,
    detectEngine = () => detectCursorEngine("repo"),
    createChannel = defaultCreateChannel,
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
  const command = source ? detectEngine() : null;
  if (source && !command) {
    res.status(503).json({
      error: "口语总结需要本机 Claude Code 或 Cursor Agent（ACP）。请安装并登录所选助手。",
      code: "acp_unconfigured",
    });
    return;
  }

  const cwd = String(store?.config?.workspaceRoot || "").trim();
  if (source && !cwd) {
    res.status(503).json({ error: "还没有工作目录，暂时不能朗读。", code: "workspace_missing" });
    return;
  }

  const signal = signalOf(req, res);
  openSse(res);
  writeSse(res, { type: "state", phase: "think" });

  let channel = null;
  try {
    if (source) {
      mkdirSync(cwd, { recursive: true });
      channel = createChannel({ command, cwd });
      await channel.start();
      channel.agentMode = false;
      await channel.applySessionMode?.().catch(() => {});
    }
    if (signal.aborted) return;

    const spoken = await runSpeakSummary({
      text,
      prompt: (promptText, opts) =>
        channel.prompt(promptText, { ...opts, timeoutMs: 90_000 }),
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
      writeSse(res, { type: "done", answer: spoken, engine: "acp" });
    }
  } catch (err) {
    if (signal.aborted || isCancelled(err)) return;
    let hint = "没能朗读这段回答，请稍后再试。";
    let code = err.code || "speak_failed";
    if (code === "empty_answer") {
      hint = "没有可朗读的内容。";
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
    await channel?.close?.().catch(() => {});
    res.end();
  }
}
