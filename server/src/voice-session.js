import { BARGE_RMS, CALL_MIN_RMS, createCallMachine, pcmRms, runVoiceTurn } from "./voice-call.js";

/** Speech long enough to be a real interrupt, not the tail of the question just asked. */
const INTERRUPT_SPEECH_BYTES = 16000 * 2 * 0.4;
/** About 0.2s of 16 kHz PCM16 loud enough to talk over the speaker. */
const PLAYBACK_BARGE_BYTES = 6400;
const PLAYBACK_BARGE_GAP_MS = 280;

export function createVoiceSession({
  config,
  send,
  sendAudio,
  checkout,
  prepareContext,
  sessions,
  ask,
  tts,
  asr,
  playbackFallbackMs = null,
} = {}) {
  const machine = createCallMachine();
  const captions = [];
  let started = false;
  let closed = false;
  let owner = "";
  let repo = "";
  let bookId = "";
  let chapter = "";
  let bookMode = false;
  let sessionId = "";
  let turnSessions = sessions;
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
  let playbackOpen = false;
  let playbackBytes = 0;
  let playbackTimer = null;
  let asrRecoverAt = 0;
  let echoLooseUntil = 0;
  let micTimer = null;
  let micFrames = 0;
  let micMax = 0;
  let heardPcmSinceTurn = false;
  let speechBytesSinceTurn = 0;
  let bargeChunks = [];
  let bargeSpeechBytes = 0;
  let bargeHardBytes = 0;
  let bargeGapTimer = null;

  function stopMicLog() {
    if (micTimer) clearInterval(micTimer);
    micTimer = null;
    micFrames = 0;
    micMax = 0;
  }

  function startMicLog() {
    stopMicLog();
    micTimer = setInterval(() => {
      if (micFrames > 0) {
        console.log(`[voice] mic frames=${micFrames} maxRms=${Math.round(micMax)}`);
      }
      micFrames = 0;
      micMax = 0;
    }, 2000);
    micTimer.unref?.();
  }

  function emit(msg) {
    if (closed) return;
    send?.(msg);
  }

  function compact(text) {
    return String(text || "").replace(/[\s，。！？、,.!?;；:：\n"'「」]/g, "");
  }

  /** Speaker bleed is often a fragment or a near-copy, not the full line. */
  function echoOfAssistant(text, { loose = false } = {}) {
    const heard = compact(text);
    const spoken = compact(assistantUtterance);
    if (!heard || !spoken) return false;
    if (loose && heard.length >= 2 && spoken.includes(heard)) return true;
    if (heard.length >= 8 && spoken.length >= 8 && (spoken.includes(heard) || heard.includes(spoken))) return true;
    if (!loose || heard.length < 6 || spoken.length < 6) return false;
    let hit = 0;
    const pairs = heard.length - 1;
    for (let i = 0; i < pairs; i += 1) {
      if (spoken.includes(heard.slice(i, i + 2))) hit += 1;
    }
    return hit / pairs >= 0.72;
  }

  /** A second decode of the question already accepted, not a new one. */
  function revisionOfAsk(text) {
    const heard = compact(text);
    const asked = compact(lastFinalText);
    if (!heard || !asked) return false;
    if (heard === asked || asked.includes(heard)) return true;
    return heard.includes(asked) && heard.length - asked.length < 4;
  }

  function interruptHasSpeech() {
    if (!heardPcmSinceTurn) return true;
    return speechBytesSinceTurn >= INTERRUPT_SPEECH_BYTES;
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
    if (currentSession) turnSessions?.cancel?.(currentSession).catch(() => {});
  }

  function clearPlaybackTimer() {
    if (playbackTimer) clearTimeout(playbackTimer);
    playbackTimer = null;
  }

  function resetPlaybackBarge() {
    bargeChunks = [];
    bargeSpeechBytes = 0;
    bargeHardBytes = 0;
    if (bargeGapTimer) clearTimeout(bargeGapTimer);
    bargeGapTimer = null;
  }

  function notePlaybackPcm(bytes, rms) {
    if (rms >= CALL_MIN_RMS) {
      if (bargeGapTimer) {
        clearTimeout(bargeGapTimer);
        bargeGapTimer = null;
      }
      bargeSpeechBytes += bytes.length;
      if (rms >= BARGE_RMS) bargeHardBytes += bytes.length;
      bargeChunks.push(bytes);
      if (bargeSpeechBytes < PLAYBACK_BARGE_BYTES || bargeHardBytes < PLAYBACK_BARGE_BYTES) return;
      const buffered = Buffer.concat(bargeChunks);
      if (!bargeIn("speech")) return;
      heardPcmSinceTurn = true;
      speechBytesSinceTurn += buffered.length;
      asr?.push?.(buffered);
      return;
    }
    if (!bargeSpeechBytes) return;
    bargeChunks.push(bytes);
    if (bargeGapTimer) return;
    bargeGapTimer = setTimeout(() => {
      bargeGapTimer = null;
      bargeChunks = [];
      bargeSpeechBytes = 0;
      bargeHardBytes = 0;
    }, PLAYBACK_BARGE_GAP_MS);
    bargeGapTimer.unref?.();
  }

  function finishListen() {
    clearPlaybackTimer();
    resetPlaybackBarge();
    playbackOpen = false;
    playbackBytes = 0;
    asr?.discard?.();
    echoLooseUntil = Date.now() + 1500;
    if (machine.state === "speaking" || machine.state === "thinking") {
      machine.listen();
      emit({ type: "state", state: "listening" });
    }
  }

  function armPlaybackWatch() {
    clearPlaybackTimer();
    const audioMs = Math.ceil((playbackBytes / 48000) * 1000);
    // Phone playback runs longer than the byte estimate (player gaps). Opening
    // the mic on a short timer lets the speaker get transcribed as the next turn.
    const ms = Math.min(120000, playbackFallbackMs == null ? audioMs + 8000 : playbackFallbackMs);
    playbackTimer = setTimeout(() => {
      playbackTimer = null;
      if (playbackOpen) finishListen();
    }, ms);
    playbackTimer.unref?.();
  }

  async function sayRetry(hint, signal) {
    pushCaption("assistant", hint, { final: true });
    if (!tts || signal?.aborted) return;
    try {
      const audio = await tts(hint, signal);
      if (signal?.aborted || !audio?.length) return;
      beginSpeaking();
      if (sendAudio) {
        const opening = !playbackOpen;
        playbackOpen = true;
        playbackBytes += audio.length;
        if (opening) {
          resetPlaybackBarge();
          asr?.discard?.();
        }
      }
      sendAudio?.(audio);
    } catch {
      /* stay on the call even when this line cannot be spoken */
    }
  }

  function bargeIn(reason = "speech") {
    const action = machine.barge();
    if (!action.stopTts && !action.cancelTurn) return false;
    clearPlaybackTimer();
    resetPlaybackBarge();
    playbackOpen = false;
    playbackBytes = 0;
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
    clearPlaybackTimer();
    playbackOpen = false;
    playbackBytes = 0;
    heardPcmSinceTurn = false;
    speechBytesSinceTurn = 0;
    abortTurn();
    asr?.discard?.();
    const gen = ++turnGen;
    turnAbort = new AbortController();
    ttsAbort = new AbortController();
    const signal = turnAbort.signal;
    machine.think();
    emit({ type: "state", state: "thinking" });
    try {
      let ctx = null;
      if (bookMode) {
        try {
          ctx = await prepareContext?.({ bookId, chapter, sessionId, signal });
        } catch {
          await sayRetry("没找到这本书", signal);
          return;
        }
        if (signal.aborted) return;
        if (!ctx?.book || !ctx?.materialized) {
          await sayRetry("没找到这本书", signal);
          return;
        }
        currentSession = ctx.session || { id: sessionId };
        sessionId = currentSession?.id || sessionId;
        turnSessions = ctx.sessions || sessions;
      } else {
        ctx = await checkout?.(owner, repo, signal);
        if (signal.aborted) return;
        turnSessions = sessions;
        currentSession = sessions?.resolveForChat?.(owner, repo, sessionId) || { id: sessionId };
        sessionId = currentSession?.id || sessionId;
      }
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
              bookId,
              chapter,
              history,
              session: currentSession,
              sessions: turnSessions,
              checkout: bookMode ? undefined : ctx,
              book: ctx?.book,
              materialized: ctx?.materialized,
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
          if (sendAudio) {
            const opening = !playbackOpen;
            playbackOpen = true;
            playbackBytes += buf?.length || 0;
            if (opening) {
              resetPlaybackBarge();
              asr?.discard?.();
            }
          }
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
      console.error(`[voice] turn ${err?.code || ""} ${err?.message || err}`);
      const ttsFailed = err?.code === "tts" || /tts/i.test(String(err?.message || ""));
      if (ttsFailed) {
        emit({ type: "caption", role: "assistant", text: "这句没说成，再说一次", final: true });
      } else {
        await sayRetry("这句没说成，再说一次", signal);
      }
    } finally {
      if (gen !== turnGen || signal.aborted) return;
      if (playbackOpen) {
        emit({ type: "state", state: "audio_done" });
        armPlaybackWatch();
        return;
      }
      finishListen();
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
      bookId = String(opts.bookId || "").trim();
      chapter = String(opts.chapter || "").trim();
      bookMode = Boolean(bookId);
      sessionId = String(opts.sessionId || "").trim();
      history = Array.isArray(opts.history) ? opts.history : [];
      turnSessions = sessions;
      if (!config?.ready) {
        emit({ type: "error", code: "unconfigured", hint: config?.hint || "还没配语音密钥" });
        return;
      }
      if (!bookMode && (!owner || !repo)) {
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
        startMicLog();
      } catch (err) {
        started = false;
        machine.fail();
        const detail = String(err?.message || err || "").slice(0, 400);
        console.error(`[voice] start ${detail}`);
        emit({ type: "error", code: "channel", hint: "通话断了", detail });
      }
    },
    onTranscript(text, { final = false } = {}) {
      const spoken = String(text || "").trim();
      if (!spoken || !started) return;
      // Speaker audio is still in the room until the phone finishes this clip.
      // A final that does not match the line used to become the next question.
      if (playbackOpen) return;
      const busy = machine.state === "speaking" || machine.state === "thinking";
      if (echoOfAssistant(spoken, { loose: busy || Date.now() < echoLooseUntil })) return;
      if (busy && compact(spoken).length < 4) return;
      if (busy && revisionOfAsk(spoken)) return;
      if (final && spoken === lastFinalText) {
        const now = Date.now();
        // Recognition often repeats the line it just accepted. Cutting the
        // answer on that repeat makes the call stutter a few seconds in.
        if (busy || now - lastFinalAt < 1200) return;
      }
      // Partials keep arriving while the answer is still being written.
      // Cancelling on one of them drops the question and nothing is said.
      if (busy && !final) return;
      if (busy && !interruptHasSpeech()) return;
      if (machine.state === "speaking" || machine.state === "thinking") bargeIn("asr");
      pushCaption("user", spoken, { final });
      if (!final) return;
      lastFinalText = spoken;
      lastFinalAt = Date.now();
      runAsk(spoken).catch(() => {});
    },
    onPcm(buf) {
      if (!started || closed) return;
      const bytes = Buffer.isBuffer(buf) ? buf : Buffer.from(buf || []);
      if (!bytes.length) return;
      micFrames += 1;
      const rms = pcmRms(bytes);
      if (rms > micMax) micMax = rms;
      // Speaker bleed stays out of recognition. A loud stretch talks over it.
      if (playbackOpen) {
        notePlaybackPcm(bytes, rms);
        return;
      }
      heardPcmSinceTurn = true;
      if (rms >= CALL_MIN_RMS) speechBytesSinceTurn += bytes.length;
      asr?.push?.(bytes);
    },
    onAsrFailure(message) {
      if (!started || closed) return;
      console.error(`[voice] asr ${String(message || "failed")}`);
      const busy = playbackOpen || machine.state === "speaking" || machine.state === "thinking";
      if (!busy) {
        emit({ type: "caption", role: "assistant", text: "没听清，再说一次", final: true });
      }
      const now = Date.now();
      if (now < asrRecoverAt) return;
      asrRecoverAt = now + 3000;
      Promise.resolve()
        .then(async () => {
          if (closed || !started) return;
          asr?.stop?.();
          await asr?.start?.();
        })
        .catch((err) => {
          console.error(`[voice] asr restart ${err?.message || err}`);
        });
    },
    barge(reason = "tap") {
      if (reason !== "tap" && playbackOpen) return;
      if (machine.state === "speaking" || machine.state === "thinking") {
        bargeIn(reason === "tap" ? "tap" : "speech");
      }
    },
    playbackDone() {
      if (!playbackOpen) return;
      finishListen();
    },
    hangup() {
      closed = true;
      started = false;
      clearPlaybackTimer();
      resetPlaybackBarge();
      stopMicLog();
      abortTurn();
      asr?.stop?.();
      machine.hangup();
    },
  };
}
