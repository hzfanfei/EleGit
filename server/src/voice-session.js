import { encodeAdpcm } from "./adpcm.js";
import { CALL_MIN_RMS, createCallMachine, pcmRms, runVoiceTurn } from "./voice-call.js";

/** Speech long enough to be a real interrupt, not the tail of the question just asked. */
const INTERRUPT_SPEECH_BYTES = 16000 * 2 * 0.4;
/**
 * About 0.25s of 16 kHz PCM16 above conversation level.
 * 1400 was louder than a phone mic usually gets while the speaker is on, so a
 * normal interruption never reached recognition and the call stayed on 在说.
 */
const PLAYBACK_BARGE_RMS = 800;
/**
 * vivo's call echo cancel leaves the speaker at 0-40 RMS but also squeezes the
 * user's voice to 80-400 while it plays, so 800 never fires there. The first second
 * of the call's first playback measures the echo; the bar then stays put for the call.
 * Tracking a running echo peak let the user's own squeezed voice push the bar up
 * past itself, and the answer talked on.
 */
const PLAYBACK_BARGE_MIN_RMS = 100;
const PLAYBACK_ECHO_MARGIN = 2.5;
const PLAYBACK_ECHO_LEARN_BYTES = 16000 * 2 * 1;
/**
 * TTS runs 3-5x faster than playback. Sending every sentence at once stacked
 * seconds of audio on the tunnel, which starved the mic upload and still had to
 * drain after a barge. Stay at most this far ahead of the phone's speaker.
 */
const PLAYBACK_AHEAD_MS = 4000;
const PCM_BYTES_PER_MS = 48;
/**
 * Unsent bytes on the socket. State messages queue behind audio, so a stalled
 * link kept the phone on 在说 after a barge. Hold further audio past this.
 */
const DOWNLINK_BACKLOG_BYTES = 32 * 1024;

function looksLikeMp3(buf) {
  if (!buf || buf.length < 3) return false;
  if (buf[0] === 0x49 && buf[1] === 0x44 && buf[2] === 0x33) return true;
  return buf[0] === 0xff && (buf[1] & 0xe0) === 0xe0;
}

function sleep(ms, signal) {
  return new Promise((resolve) => {
    if (signal?.aborted) return resolve();
    const timer = setTimeout(done, ms);
    function done() {
      clearTimeout(timer);
      signal?.removeEventListener?.("abort", done);
      resolve();
    }
    signal?.addEventListener?.("abort", done, { once: true });
  });
}
const PLAYBACK_BARGE_BYTES = 16000 * 2 * 0.25;
/**
 * The squeezed interruption sits under Xiaomi's speech floor, so its gate threw the
 * words away and the call went quiet. Lift it to talking level for such recognizers,
 * for the barge audio and until the phone has stopped its speaker.
 */
const BARGE_LIFT_RMS = 1500;
const BARGE_LIFT_MIN_RMS = 60;
const BARGE_LIFT_MAX_GAIN = 12;
const BARGE_LIFT_MS = 1200;

function liftQuietSpeech(buf, floorRms) {
  const rms = pcmRms(buf);
  if (rms >= floorRms || rms < BARGE_LIFT_MIN_RMS) return buf;
  const gain = Math.min(BARGE_LIFT_MAX_GAIN, BARGE_LIFT_RMS / rms);
  const out = Buffer.alloc(buf.length - (buf.length % 2));
  for (let i = 0; i < out.length; i += 2) {
    out.writeInt16LE(Math.max(-32768, Math.min(32767, Math.round(buf.readInt16LE(i) * gain))), i);
  }
  return out;
}
// A breath or an echo-cancel hole must not wipe the sentence being spoken over the answer.
const PLAYBACK_BARGE_GAP_MS = 1100;

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
  socketBacklog,
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
  let micMaxPlaying = -1;
  let heardPcmSinceTurn = false;
  let speechBytesSinceTurn = 0;
  let bargeChunks = [];
  let bargeSpeechBytes = 0;
  let bargeHardBytes = 0;
  let echoBytes = 0;
  let echoLevels = [];
  let callBargeRms = null;
  let bargeLiftUntil = 0;
  let speakerBusyUntil = 0;
  let downlinkAdpcm = false;

  function pushAudio(buf) {
    sendAudio?.(downlinkAdpcm && buf?.length && !looksLikeMp3(buf) ? encodeAdpcm(buf, 24000) : buf);
  }
  let bargeGapTimer = null;
  let checkoutPromise = null;
  const callAbort = new AbortController();

  /** One local checkout per call. It used to run again after every question. */
  function repoCheckout() {
    if (!checkoutPromise) {
      checkoutPromise = Promise.resolve(checkout?.(owner, repo, callAbort.signal)).catch((err) => {
        checkoutPromise = null;
        throw err;
      });
    }
    return checkoutPromise;
  }

  /** The first question should not wait for the Agent process to start. */
  function warmRepoCall() {
    repoCheckout()
      .then((ctx) => {
        if (closed) return;
        const chat = sessions?.resolveForChat?.(owner, repo, sessionId);
        if (chat?.id) sessionId = chat.id;
        const cwd = ctx?.local?.present ? ctx.local.path : "";
        if (cwd) return sessions?.warmRepo?.(owner, repo, cwd);
      })
      .catch(() => {});
  }

  function stopMicLog() {
    if (micTimer) clearInterval(micTimer);
    micTimer = null;
    micFrames = 0;
    micMax = 0;
    micMaxPlaying = -1;
  }

  function startMicLog() {
    stopMicLog();
    micTimer = setInterval(() => {
      if (micFrames > 0) {
        const time = new Date().toTimeString().slice(0, 8);
        const playing = micMaxPlaying >= 0 ? ` playingRms=${Math.round(micMaxPlaying)} bar=${Math.round(playbackBargeRms())}` : "";
        const backlog = socketBacklog?.() || 0;
        const sendq = backlog ? ` sendq=${Math.round(backlog / 1024)}KB` : "";
        console.log(`[voice] ${time} mic frames=${micFrames} maxRms=${Math.round(micMax)}${playing}${sendq} state=${machine.state}`);
      }
      micFrames = 0;
      micMax = 0;
      micMaxPlaying = -1;
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
    if (heard.length >= 8 && spoken.length >= 8) {
      const contained = spoken.includes(heard) || heard.includes(spoken);
      if (contained) {
        const shorter = Math.min(heard.length, spoken.length);
        const longer = Math.max(heard.length, spoken.length);
        // A follow-up can share a few words with the answer. Only a near-copy is the speaker.
        if (shorter / longer >= 0.6) return true;
      }
    }
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
    echoBytes = 0;
    echoLevels = [];
    if (bargeGapTimer) clearTimeout(bargeGapTimer);
    bargeGapTimer = null;
  }

  function playbackBargeRms() {
    return callBargeRms ?? PLAYBACK_BARGE_RMS;
  }

  function learnEcho(bytes, rms) {
    if (callBargeRms != null) return;
    echoLevels.push(rms);
    echoBytes += bytes.length;
    if (echoBytes < PLAYBACK_ECHO_LEARN_BYTES) return;
    const sorted = [...echoLevels].sort((a, b) => a - b);
    const echo = sorted[Math.min(sorted.length - 1, Math.floor(sorted.length * 0.9))];
    callBargeRms = Math.min(PLAYBACK_BARGE_RMS, Math.max(PLAYBACK_BARGE_MIN_RMS, echo * PLAYBACK_ECHO_MARGIN));
  }

  function notePlaybackPcm(bytes, rms) {
    const bar = playbackBargeRms();
    learnEcho(bytes, rms);
    if (rms >= bar) {
      if (bargeGapTimer) {
        clearTimeout(bargeGapTimer);
        bargeGapTimer = null;
      }
      bargeSpeechBytes += bytes.length;
      bargeHardBytes += bytes.length;
      bargeChunks.push(bytes);
      if (bargeHardBytes < PLAYBACK_BARGE_BYTES) return;
      const chunks = bargeChunks;
      if (!bargeIn("speech")) return;
      heardPcmSinceTurn = true;
      const floor = asr?.speechFloorRms;
      if (floor) bargeLiftUntil = Date.now() + BARGE_LIFT_MS;
      const buffered = Buffer.concat(floor ? chunks.map((c) => liftQuietSpeech(c, floor)) : chunks);
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
      pushAudio(audio);
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
    speakerBusyUntil = 0;
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
    bargeLiftUntil = 0;
    speakerBusyUntil = 0;
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
        ctx = await repoCheckout(signal);
        if (signal.aborted) return;
        turnSessions = sessions;
        currentSession = sessions?.resolveForChat?.(owner, repo, sessionId) || { id: sessionId };
        sessionId = currentSession?.id || sessionId;
      }
      const result = await runVoiceTurn({
        question,
        signal,
        tts: (text, ttsSignal) => tts?.(text, ttsSignal || ttsAbort.signal),
        ttsStream: tts?.stream
          ? (text, ttsSignal, onPcm) => tts.stream(text, ttsSignal || ttsAbort.signal, onPcm)
          : undefined,
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
          if (!looksLikeMp3(buf)) {
            const ahead = speakerBusyUntil - Date.now();
            if (ahead > PLAYBACK_AHEAD_MS) await sleep(ahead - PLAYBACK_AHEAD_MS, signal);
            while (!signal.aborted && (socketBacklog?.() || 0) > DOWNLINK_BACKLOG_BYTES) await sleep(50, signal);
            if (signal.aborted) return;
            speakerBusyUntil = Math.max(Date.now(), speakerBusyUntil) + (buf?.length || 0) / PCM_BYTES_PER_MS;
          }
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
          pushAudio(buf);
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
      downlinkAdpcm = opts.audio === "adpcm";
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
          audio: downlinkAdpcm ? "adpcm" : "pcm",
        });
        emit({ type: "state", state: "listening" });
        startMicLog();
        if (!bookMode) warmRepoCall();
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
      if (playbackOpen && rms > micMaxPlaying) micMaxPlaying = rms;
      // 在听 must take the next sentence. A stuck playback flag used to drop it.
      if (machine.state === "listening" && playbackOpen) {
        clearPlaybackTimer();
        resetPlaybackBarge();
        playbackOpen = false;
        playbackBytes = 0;
      }
      // Speaker bleed stays out of recognition. A stretch of the user's voice talks over it.
      if (playbackOpen) {
        notePlaybackPcm(bytes, rms);
        return;
      }
      heardPcmSinceTurn = true;
      const lifted = asr?.speechFloorRms && Date.now() < bargeLiftUntil ? liftQuietSpeech(bytes, asr.speechFloorRms) : bytes;
      if (lifted === bytes ? rms >= CALL_MIN_RMS : pcmRms(lifted) >= CALL_MIN_RMS) speechBytesSinceTurn += bytes.length;
      asr?.push?.(lifted);
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
      callAbort.abort();
      clearPlaybackTimer();
      resetPlaybackBarge();
      stopMicLog();
      abortTurn();
      asr?.stop?.();
      machine.hangup();
    },
  };
}
