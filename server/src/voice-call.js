import { isSpeakableTtsText, isUnreadableTtsError, speakTextInParts } from "./spoken-tts.js";

const SPEAK_PUNCT = /[。！？!?；;\n]/;

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
    speak() {
      if (state === "listening" || state === "barge") state = "speaking";
    },
    barge() {
      if (state !== "speaking") {
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

export function takeSpeakable(buffer, hardLen = 72) {
  const text = String(buffer || "");
  let last = -1;
  for (let i = 0; i < text.length; i += 1) {
    if (SPEAK_PUNCT.test(text[i])) last = i;
  }
  if (last >= 0) {
    return { speak: text.slice(0, last + 1).trim(), rest: text.slice(last + 1) };
  }
  if (text.length >= hardLen) {
    return { speak: text.trim(), rest: "" };
  }
  return { speak: "", rest: text };
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
      : takeSpeakable(pending, maxSpeakChars ? 32 : 72);
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
