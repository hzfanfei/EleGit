import { isSpeakableTtsText, isUnreadableTtsError, speakTextInParts } from "./spoken-tts.js";

/** Sentence ends only. Semicolons and commas stay inside one spoken segment. */
const SENTENCE_END = /[。！？!?\n]/;
/** Fallback pause when a clause has no sentence end and exceeds SPEAK_HARD_LEN. */
const CLAUSE_PAUSE = /[，,、；;]/;
const SPEAK_HARD_LEN = 320;

export function createCallMachine() {
  let state = "idle";
  return {
    get state() {
      return state;
    },
    start() {
      state = "connecting";
    },
    connected() {
      if (state === "connecting" || state === "idle") state = "listening";
    },
    think() {
      if (state === "listening" || state === "barge") state = "thinking";
    },
    speak() {
      if (state === "listening" || state === "barge" || state === "thinking") state = "speaking";
    },
    listen() {
      if (state === "speaking" || state === "thinking" || state === "barge" || state === "connecting" || state === "idle") {
        state = "listening";
      }
    },
    barge() {
      if (state !== "speaking" && state !== "thinking") {
        return { stopTts: false, cancelTurn: false };
      }
      state = "barge";
      return { stopTts: true, cancelTurn: true };
    },
    afterBarge() {
      if (state === "barge") state = "listening";
    },
    fail() {
      state = "idle";
    },
    hangup() {
      state = "idle";
    },
  };
}

export function takeSpeakable(buffer, hardLen = SPEAK_HARD_LEN) {
  const text = String(buffer || "");
  if (!text) return { speak: "", rest: "" };
  let lastSentence = -1;
  for (let i = 0; i < text.length; i += 1) {
    if (SENTENCE_END.test(text[i])) lastSentence = i;
  }
  if (lastSentence >= 0) {
    return {
      speak: text.slice(0, lastSentence + 1).trim(),
      rest: text.slice(lastSentence + 1),
    };
  }
  if (text.length < hardLen) return { speak: "", rest: text };
  let lastClause = -1;
  for (let i = 0; i < text.length; i += 1) {
    if (CLAUSE_PAUSE.test(text[i])) lastClause = i;
  }
  if (lastClause >= 24) {
    return {
      speak: text.slice(0, lastClause + 1).trim(),
      rest: text.slice(lastClause + 1),
    };
  }
  return { speak: text.slice(0, hardLen).trim(), rest: text.slice(hardLen) };
}

export function pcmRms(buf) {
  const bytes = Buffer.isBuffer(buf) ? buf : Buffer.from(buf || []);
  if (bytes.length < 2) return 0;
  let sum = 0;
  let n = 0;
  for (let i = 0; i + 1 < bytes.length; i += 2) {
    const sample = bytes.readInt16LE(i);
    sum += sample * sample;
    n += 1;
  }
  return n ? Math.sqrt(sum / n) : 0;
}

export function pcmHasSpeech(buf, threshold = 1800) {
  return pcmRms(buf) >= threshold;
}

/** Phone call audio is often quieter than a raw mic, and one soft frame is not a pause. */
export const CALL_MIN_RMS = 420;
const BARGE_RMS = 1400;

export function createUtteranceGate({
  minRms = CALL_MIN_RMS,
  bargeRms = BARGE_RMS,
  endpointSilenceMs = 700,
  armHangMs = 280,
  maxUtteranceMs = 8000,
  minEndpointBytes = 12800,
  speechStartBytes = 6400,
  onSpeechStart,
  onEndpoint,
  now = Date.now,
  setTimer = setTimeout,
  clearTimer = clearTimeout,
} = {}) {
  const chunks = [];
  let speechBytes = 0;
  let hardBytes = 0;
  let announced = false;
  let startedAt = null;
  let endpointTimer = null;
  let armTimer = null;

  function clearEndpoint() {
    if (!endpointTimer) return;
    clearTimer(endpointTimer);
    endpointTimer = null;
  }

  function clearArm() {
    if (!armTimer) return;
    clearTimer(armTimer);
    armTimer = null;
  }

  function reset() {
    chunks.length = 0;
    speechBytes = 0;
    hardBytes = 0;
    announced = false;
    startedAt = null;
    clearEndpoint();
    clearArm();
  }

  function take(force) {
    const buf = chunks.length ? Buffer.concat(chunks) : Buffer.alloc(0);
    const ready = buf.length >= minEndpointBytes && (announced || force);
    reset();
    return ready ? buf : null;
  }

  function finish(reason) {
    const buf = take(false);
    if (buf) onEndpoint?.(buf, { reason });
  }

  return {
    push(pcm) {
      if (!pcm?.length) return;
      const buf = Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm);
      const rms = pcmRms(buf);
      if (rms >= minRms) {
        clearArm();
        clearEndpoint();
        if (startedAt == null) startedAt = now();
        speechBytes += buf.length;
        if (rms >= bargeRms) hardBytes += buf.length;
        chunks.push(buf);
        if (!announced && speechBytes >= speechStartBytes) {
          announced = true;
          if (hardBytes >= speechStartBytes) onSpeechStart?.();
        }
        if (announced && now() - startedAt >= maxUtteranceMs) finish("max");
        return;
      }
      if (!speechBytes) return;
      chunks.push(buf);
      if (!announced) {
        if (!armTimer) {
          armTimer = setTimer(() => {
            armTimer = null;
            reset();
          }, armHangMs);
        }
        return;
      }
      if (!endpointTimer) {
        endpointTimer = setTimer(() => {
          endpointTimer = null;
          finish("quiet");
        }, endpointSilenceMs);
      }
    },
    reset,
    flush() {
      clearEndpoint();
      clearArm();
      const buf = chunks.length ? Buffer.concat(chunks) : Buffer.alloc(0);
      const ready = buf.length >= minEndpointBytes && speechBytes >= speechStartBytes;
      reset();
      return ready ? buf : Buffer.alloc(0);
    },
  };
}

export async function runVoiceTurn({
  question,
  ask,
  tts,
  signal,
  onDelta,
  onCaption,
  onAudio,
  onDone,
  maxSpeakChars = 0,
  /** `stream` = TTS while tokens arrive; `final` = one TTS after answer completes */
  speakStrategy = "stream",
}) {
  let pending = "";
  let full = "";
  let engine = "local-progress";
  const speakQueue = [];
  let speaking = Promise.resolve();
  let speakFail = null;
  let spokenChars = 0;
  let capped = false;
  let emittedAudio = false;

  const playAudio = async (buf) => {
    if (!buf?.length) return;
    emittedAudio = true;
    await onAudio?.(buf);
  };

  const speakOne = async (speak) => {
    if (signal?.aborted || speakFail) return;
    if (!isSpeakableTtsText(speak)) return;
    onCaption?.(speak);
    try {
      let audio = await tts(speak, signal);
      if (!audio?.length && !signal?.aborted) {
        audio = await tts(speak, signal);
      }
      if (signal?.aborted || !audio?.length) return;
      await playAudio(audio);
    } catch (err) {
      if (signal?.aborted || isUnreadableTtsError(err)) return;
      speakFail = err;
    }
  };

  const capChunk = (piece) => {
    if (!maxSpeakChars || !piece) return piece;
    const remain = maxSpeakChars - spokenChars;
    if (remain <= 0) {
      capped = true;
      return "";
    }
    const chars = [...piece];
    if (chars.length <= remain) return piece;
    capped = true;
    return chars.slice(0, remain).join("");
  };

  const flush = (force = false) => {
    if (speakStrategy === "final") return;
    if (capped && !force) return;
    const chunk = force
      ? { speak: pending.trim(), rest: "" }
      : takeSpeakable(pending);
    if (!chunk.speak) {
      pending = chunk.rest || pending;
      return;
    }
    pending = chunk.rest;
    const speak = capChunk(chunk.speak);
    if (!speak) return;
    spokenChars += [...speak].length;
    speakQueue.push(speak);
    speaking = speaking.then(() => speakOne(speak)).catch((err) => {
      speakFail = speakFail || err;
    });
  };

  for await (const event of ask(question, signal)) {
    if (signal?.aborted) break;
    if (event.type === "start" && event.engine) engine = event.engine;
    if (event.type === "delta" && event.text) {
      full += event.text;
      pending += event.text;
      onDelta?.({ text: full, engine, final: false });
      flush(false);
    }
    if (event.type === "done") {
      engine = event.engine || engine;
      if (event.answer && !full) {
        full = event.answer;
        pending = event.answer;
      }
    }
  }
  if (speakStrategy !== "final" && !signal?.aborted) flush(true);
  try {
    await speaking;
    if (speakFail) throw speakFail;
  } catch (err) {
    if (signal?.aborted) return { engine, answer: full, cancelled: true };
    throw err;
  }
  if (speakStrategy === "final" && !signal?.aborted) {
    await speakTextInParts({ text: full, tts, onCaption, onAudio: playAudio, signal });
  }
  if (!signal?.aborted && !emittedAudio) {
    const err = new Error("没有可朗读的回答内容");
    err.code = "empty_answer";
    throw err;
  }
  if (!signal?.aborted) onDone?.({ text: full, engine, final: true });
  return { engine, answer: full, cancelled: Boolean(signal?.aborted) };
}
