import { buildBookAcpPrompt, detectCursorEngine } from "./acp.js";
import { streamAnswer, synthesizeBookAnswer } from "./ask.js";
import {
  bookLocalView,
  bookSessionOwner,
  emptyBookProgress,
  ensureBookMaterialized,
  formatBookAcpContext,
  resolveBook,
} from "./books.js";
import { requestSignal } from "./http-signal.js";
import { openSse, writeSse } from "./sse.js";
import { BOOK_VOICE_SPEAK_STRATEGY } from "./book-voice-latency.js";
import { writeAudioToSse } from "./spoken-tts.js";
import { runVoiceTurn } from "./voice-call.js";
import { resolveTurnTtsVoice, resolveVoiceConfig, withTtsVoice } from "./voice-config.js";
import { createVoiceProviders } from "./voice-ws.js";

export function createBookAskIterator({
  book,
  materialized,
  session,
  bookSessions,
  chapter,
  history,
  signal,
}) {
  return async function* ask(question, askSignal) {
    const bookContext = await formatBookAcpContext(book, materialized);
    const local = bookLocalView(materialized, book);
    const progress = emptyBookProgress(book);
    const mergedSignal = askSignal || signal;
    yield* streamAnswer({
      question,
      history,
      progress,
      context: bookContext,
      bookContext,
      local,
      session,
      sessions: bookSessions,
      buildPrompt: (opts) =>
        buildBookAcpPrompt({
          ...opts,
          currentChapter: chapter || undefined,
          spokenAnswer: true,
        }),
      synthesize: (opts) =>
        synthesizeBookAnswer({ ...opts, question, book, bookContext, local }),
      signal: mergedSignal,
      detectEngine: () => detectCursorEngine("book"),
    });
  };
}

export async function handleBookVoiceTurn(
  req,
  res,
  {
    store,
    bookSessions,
    resolveConfig = resolveVoiceConfig,
    createProviders = createVoiceProviders,
    detectEngine = () => detectCursorEngine("book"),
  },
) {
  const bookId = String(req.body?.bookId || "").trim();
  const message = String(req.body?.message || "").trim();
  const sessionId = String(req.body?.sessionId || "").trim();
  const chapter = String(req.body?.chapter || "").trim();
  const history = Array.isArray(req.body?.history) ? req.body.history : [];

  if (!bookId || !message) {
    res.status(400).json({ error: "bookId and message are required" });
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
      error: "问书需要本机 Claude Code 或 Cursor Agent（ACP）。请安装并登录所选助手。",
      code: "acp_unconfigured",
    });
    return;
  }

  const signal = requestSignal(req, res);
  openSse(res);
  writeSse(res, { type: "state", phase: "connect" });

  let session = null;
  try {
    const book = await resolveBook(store.config.workspaceRoot, bookId);
    const materialized = await ensureBookMaterialized(store.config.workspaceRoot, book);
    const owner = bookSessionOwner();
    session = bookSessions.resolveForChat(owner, bookId, sessionId);
    writeSse(res, { type: "meta", sessionId: session.id, bookId: book.id });
    req.on("close", () => {
      bookSessions.cancel?.(session).catch(() => {});
    });
    await bookSessions.warm(session, materialized.cacheDir).catch(() => {});
    if (signal.aborted) {
      res.end();
      return;
    }

    writeSse(res, { type: "state", phase: "think" });
    const ask = createBookAskIterator({
      book,
      materialized,
      session,
      bookSessions,
      chapter,
      history,
      signal,
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
        });
      },
    });
  } catch (err) {
    if (!signal.aborted) {
      let hint = String(err.message || "语音回答失败");
      let code = err.code || "turn_failed";
      if (code === "empty_answer") {
        hint = "没有可朗读的内容，请换个问法再试。";
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
