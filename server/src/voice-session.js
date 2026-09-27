import { createCallMachine, runVoiceTurn } from "./voice-call.js";

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
  let acceptInterruptFinal = false;
  let turnGen = 0;
  let assistantUtterance = "";
  let lastFinalText = "";
  let lastFinalAt = 0;

  function emit(msg) {
    if (closed) return;
    send?.(msg);
  }

  function echoOfAssistant(text) {
    const heard = String(text || "").replace(/[\s，。！？、,.!?\n]/g, "");
    const spoken = assistantUtterance.replace(/[\s，。！？、,.!?\n]/g, "");
    if (heard.length < 8 || spoken.length < 8) return false;
    return spoken.includes(heard);
  }

  function pushCaption(role, text, extra = {}) {
    if (role === "assistant" && text) assistantUtterance = text;
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
    if (reason !== "tap") acceptInterruptFinal = true;
    return true;
  }

  function beginSpeaking() {
    if (machine.state === "speaking") return;
    machine.speak();
    if (machine.state === "speaking") emit({ type: "state", state: "speaking" });
  }

  async function runAsk(question) {
    const fromInterrupt = acceptInterruptFinal;
    if (!fromInterrupt && Date.now() < bargeHoldUntil) return;
    acceptInterruptFinal = false;
    abortTurn();
    const gen = ++turnGen;
    turnAbort = new AbortController();
    ttsAbort = new AbortController();
    const signal = turnAbort.signal;
    machine.think();
    emit({ type: "state", state: "thinking" });
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
        onDelta: ({ text, engine, final }) => {
          beginSpeaking();
          pushCaption("assistant", text, { engine, final });
        },
        onAudio: async (buf) => {
          if (signal.aborted) return;
          beginSpeaking();
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
      if (gen === turnGen && (machine.state === "speaking" || machine.state === "thinking")) {
        machine.listen();
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
      if (echoOfAssistant(spoken)) return;
      if (machine.state === "speaking" || machine.state === "thinking") bargeIn("asr");
      pushCaption("user", spoken, { final });
      if (!final) return;
      const now = Date.now();
      if (spoken === lastFinalText && now - lastFinalAt < 1200) return;
      lastFinalText = spoken;
      lastFinalAt = now;
      runAsk(spoken).catch(() => {});
    },
    onPcm(buf) {
      if (!started || closed) return;
      asr?.push?.(buf);
    },
    barge(reason = "tap") {
      if (machine.state === "speaking" || machine.state === "thinking") {
        bargeIn(reason === "tap" ? "tap" : "speech");
      }
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
