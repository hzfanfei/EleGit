import { createCallMachine, pcmHasSpeech, runVoiceTurn } from "./voice-call.js";

export function createVoiceSession({
  config,
  send,
  sendAudio,
  checkout,
  sessions,
  ask,
  tts,
  asr,
} = {}) {
  const machine = createCallMachine();
  const captions = [];
  let started = false;
  let closed = false;
  let owner = "";
  let repo = "";
  let sessionId = "";
  let history = [];
  let turnAbort = null;
  let ttsAbort = null;
  let currentSession = null;
  let bargeHoldUntil = 0;

  function emit(msg) {
    if (closed) return;
    send?.(msg);
  }

  function pushCaption(role, text, extra = {}) {
    const caption = { type: "caption", role, text, final: Boolean(extra.final), engine: extra.engine };
    if (caption.final && text) {
      captions.push({ role, content: text, engine: extra.engine });
    }
    emit(caption);
  }

  function abortTurn() {
    try {
      ttsAbort?.abort();
    } catch {
      /* ignore */
    }
    try {
      turnAbort?.abort();
    } catch {
      /* ignore */
    }
    if (currentSession) sessions?.cancel?.(currentSession).catch(() => {});
  }

  function bargeIn(reason = "speech") {
    const action = machine.barge();
    if (!action.stopTts && !action.cancelTurn) return false;
    abortTurn();
    emit({ type: "state", state: "barge", reason });
    machine.afterBarge();
    emit({ type: "state", state: "listening" });
    bargeHoldUntil = Date.now() + 350;
    return true;
  }

  async function runAsk(question) {
    if (Date.now() < bargeHoldUntil) return;
    abortTurn();
    turnAbort = new AbortController();
    ttsAbort = new AbortController();
    const signal = turnAbort.signal;
    machine.speak();
    emit({ type: "state", state: "speaking" });
    try {
      const ctx = await checkout?.(owner, repo, signal);
      if (signal.aborted) return;
      currentSession = sessions?.resolveForChat?.(owner, repo, sessionId) || { id: sessionId };
      sessionId = currentSession?.id || sessionId;
      const result = await runVoiceTurn({
        question,
        signal,
        tts: (text, ttsSignal) => tts?.(text, ttsSignal || ttsAbort.signal),
        ask: (q, askSignal) =>
          ask?.(
            {
              question: q,
              owner,
              repo,
              history,
              session: currentSession,
              sessions,
              checkout: ctx,
              signal: askSignal,
            },
            askSignal,
          ),
        onDelta: ({ text, engine, final }) => pushCaption("assistant", text, { engine, final }),
        onAudio: async (buf) => {
          if (signal.aborted) return;
          sendAudio?.(buf);
        },
        onDone: ({ text, engine }) => {
          pushCaption("assistant", text, { engine, final: true });
          if (text) history = [...history, { role: "user", content: question }, { role: "assistant", content: text, engine }];
        },
      });
      if (!signal.aborted && result?.answer && !captions.some((c) => c.role === "assistant" && c.content === result.answer)) {
        pushCaption("assistant", result.answer, { engine: result.engine, final: true });
      }
    } catch (err) {
      if (signal.aborted || err?.code === "cancelled") return;
      emit({ type: "error", code: "turn", hint: "通话断了" });
    } finally {
      if (machine.state === "speaking") {
        machine.connected();
        emit({ type: "state", state: "listening" });
      }
    }
  }

  return {
    get started() {
      return started;
    },
    get state() {
      return machine.state;
    },
    captions() {
      return captions.slice();
    },
    async start(opts = {}) {
      owner = String(opts.owner || "").trim();
      repo = String(opts.repo || "").trim();
      sessionId = String(opts.sessionId || "").trim();
      history = Array.isArray(opts.history) ? opts.history : [];
      if (!config?.ready) {
        emit({ type: "error", code: "unconfigured", hint: config?.hint || "还没配语音密钥" });
        return;
      }
      if (!owner || !repo) {
        emit({ type: "error", code: "repo", hint: "还没选仓库" });
        return;
      }
      machine.start();
      emit({ type: "state", state: "connecting" });
      started = true;
      try {
        await asr?.start?.();
        machine.connected();
        emit({
          type: "hello",
          ok: true,
          inputRate: 16000,
          outputRate: 24000,
        });
        emit({ type: "state", state: "listening" });
      } catch (err) {
        started = false;
        machine.fail();
        emit({ type: "error", code: "channel", hint: "通话断了" });
      }
    },
    onTranscript(text, { final = false } = {}) {
      const spoken = String(text || "").trim();
      if (!spoken || !started) return;
      if (machine.state === "speaking") bargeIn("asr");
      pushCaption("user", spoken, { final });
      if (final) runAsk(spoken).catch(() => {});
    },
    onPcm(buf) {
      if (!started || closed) return;
      asr?.push?.(buf);
      if (machine.state === "speaking" && pcmHasSpeech(buf)) {
        bargeIn("energy");
      }
    },
    barge() {
      if (machine.state === "speaking") bargeIn("tap");
    },
    hangup() {
      closed = true;
      started = false;
      abortTurn();
      asr?.stop?.();
      machine.hangup();
    },
  };
}
