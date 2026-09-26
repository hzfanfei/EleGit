import { buildAcpPrompt, detectCursorEngine } from "./acp.js";
import { staticFilesPrompt } from "./static-files.js";
import { streamAnswer } from "./ask.js";
import {
  checkoutPath,
  formatAcpContext,
  formatLocalContext,
  isCheckoutPresent,
  snapshotCheckoutLite,
} from "./workspace.js";
import { emptyRepoProgress, formatProgressContext } from "./github.js";
import { requestSignal } from "./http-signal.js";
import { openSse, writeSse } from "./sse.js";
import { BOOK_VOICE_SPEAK_STRATEGY } from "./book-voice-latency.js";
import { writeAudioToSse } from "./spoken-tts.js";
import { runVoiceTurn } from "./voice-call.js";
import { resolveTurnTtsVoice, resolveVoiceConfig, withTtsVoice } from "./voice-config.js";
import { createVoiceProviders } from "./voice-ws.js";

export function createRepoAskIterator({
  progress,
  context,
  githubContext,
  local,
  session,
  sessions,
  history,
  signal,
  agentMode = false,
  staticFiles,
}) {
  return async function* ask(question, askSignal) {
    const mergedSignal = askSignal || signal;
    yield* streamAnswer({
      question,
      history,
      progress,
      context,
      githubContext,
      local,
      session,
      sessions,
      agentMode,
      staticFiles,
      buildPrompt: (opts) => buildAcpPrompt({ ...opts, spokenAnswer: true }),
      signal: mergedSignal,
    });
  };
}

/**
 * Resolve checkout + context for repo chat/voice (mirrors /v1/chat setup).
 */
export async function resolveRepoChatRuntime({
  store,
  owner,
  repo,
  sessions,
  signal,
  checkoutRepo,
}) {
  const destGuess = checkoutPath(store.config.workspaceRoot, owner, repo);
  const present = isCheckoutPresent(store.config.workspaceRoot, owner, repo);
  const warmPromise =
    present && detectCursorEngine("repo")
      ? sessions.warmRepo(owner, repo, destGuess).catch(() => {})
      : Promise.resolve();

  let progress;
  let dest;
  let local;
  if (present) {
    const snapPromise = snapshotCheckoutLite(destGuess);
    const [, localSnap] = await Promise.all([warmPromise, snapPromise]);
    if (localSnap?.present) {
      dest = destGuess;
      local = localSnap;
      progress = emptyRepoProgress(owner, repo, local.branch || "main");
    } else {
      ({ progress, dest, local } = await checkoutRepo(owner, repo, signal, { fast: true }));
      if (detectCursorEngine("repo")) {
        await sessions.warmRepo(owner, repo, dest).catch(() => {});
      }
    }
  } else {
    ({ progress, dest, local } = await Promise.all([
      checkoutRepo(owner, repo, signal, { fast: true }),
      warmPromise,
    ]).then(([checkout]) => checkout));
    if (detectCursorEngine("repo")) {
      await sessions.warmRepo(owner, repo, dest).catch(() => {});
    }
  }

  const localContext = formatLocalContext(local);
  const githubContext = formatAcpContext(local, progress);
  const context = `${formatProgressContext(progress)}\n\n${localContext}`;
  return { progress, dest, local, githubContext, context };
}

export async function handleRepoVoiceTurn(
  req,
  res,
  {
    store,
    sessions,
    checkoutRepo,
    resolveConfig = resolveVoiceConfig,
    createProviders = createVoiceProviders,
    detectEngine = detectCursorEngine,
  },
) {
  const owner = String(req.body?.owner || "").trim();
  const repo = String(req.body?.repo || "").trim();
  const message = String(req.body?.message || "").trim();
  const sessionId = String(req.body?.sessionId || "").trim();
  const history = Array.isArray(req.body?.history) ? req.body.history : [];
  const agentMode = req.body?.agentMode === true;

  if (!owner || !repo || !message) {
    res.status(400).json({ error: "owner, repo, and message are required" });
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

  const acp = detectEngine();
  if (!acp) {
    res.status(503).json({
      error: "问仓库需要本机 Claude Code 或 Cursor Agent（ACP）。请安装并登录所选助手。",
      code: "acp_unconfigured",
    });
    return;
  }

  const signal = requestSignal(req, res);
  openSse(res);
  writeSse(res, { type: "state", phase: "connect" });

  let session = null;
  try {
    session = sessions.resolveForChat(owner, repo, sessionId);
    writeSse(res, { type: "meta", sessionId: session.id, owner, repo });
    req.on("close", () => {
      sessions.cancel?.(session).catch(() => {});
    });

    writeSse(res, { type: "state", phase: "think" });
    const { progress, dest, local, githubContext, context } = await resolveRepoChatRuntime({
      store,
      owner,
      repo,
      sessions,
      signal,
      checkoutRepo,
    });
    if (signal.aborted) {
      res.end();
      return;
    }
    await sessions.warm(session, dest).catch(() => {});

    const ask = createRepoAskIterator({
      progress,
      context,
      githubContext,
      local,
      session,
      sessions,
      history,
      signal,
      agentMode,
      staticFiles: staticFilesPrompt(store?.config),
    });

    await runVoiceTurn({
      question: message,
      signal,
      ask,
      speakStrategy: BOOK_VOICE_SPEAK_STRATEGY,
      tts: (text, ttsSignal) => providers.tts(text, ttsSignal),
      onDelta: () => {},
      onCaption: (text) => {
        if (signal.aborted || !String(text || "").trim()) return;
        writeSse(res, { type: "caption", text: String(text) });
      },
      onAudio: async (buf) => {
        if (signal.aborted || !buf?.length) return;
        writeSse(res, { type: "state", phase: "speak" });
        writeAudioToSse(res, (r, ev) => writeSse(r, { type: "audio", ...ev }), buf, voiceConfig, signal);
      },
      onDone: ({ text, engine }) => {
        writeSse(res, {
          type: "done",
          engine,
          answer: text,
          sessionId: session.id,
          owner,
          repo,
          checkout: dest,
        });
      },
    });
  } catch (err) {
    if (!signal.aborted) {
      let hint = String(err.message || "语音回答失败");
      let code = err.code || "turn_failed";
      if (code === "empty_answer") {
        hint = "没有可朗读的内容，请换个问法再试。";
      } else if (code === "github_required") {
        hint = "尚未登录 GitHub，无法准备仓库。请先在 App 里登录。";
      } else if (/tts/i.test(hint) || err.status === 401 || err.status === 403) {
        code = "tts_failed";
        hint =
          voiceConfig.ttsProvider === "xiaomi"
            ? "语音合成失败，请检查本机 .env 里的 XIAOMI_MIMO_TOKEN。"
            : "语音合成失败，请检查本机 .env 里的火山 TTS 配置。";
      } else if (hint.length > 200 || !/[\u4e00-\u9fff]/.test(hint)) {
        hint = "快问快答失败，请稍后重试。";
      }
      writeSse(res, { type: "error", code, hint });
    }
  } finally {
    res.end();
  }
}
