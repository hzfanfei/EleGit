import { speakTextInParts } from "./spoken-tts.js";

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

const FILLER_PREFIX =
  /^(?:嗯[，,、]?|好[的]?[，,、]?|那么[，,、]?|首先[，,、]?|简单来说[，,、]?|总的来说[，,、]?|整体来说[，,、]?|一句话[，,、]?|简单说[，,、]?)/u;
const FILLER_PREFIX2 =
  /^(?:根据(?:书中|本书|原文|这一章|上下文)(?:的)?(?:内容)?[，,、]?|从(?:书中|本书|这一章|上下文)(?:来看|可知)[，,、]?|关于(?:你问的|这个)?问题[，,、]?|你问(?:的)?(?:这个)?[，,、]?|需要注意的是[，,、]?|值得一提的是[，,、]?|我认为[，,、]?|我的理解[是，,、]?|总结(?:来说)?[，,、]?|综上[，,、]?|分析(?:下来|之后)?[，,、]?|查(?:完|了一下|阅完)[，,、]?|看(?:完|了一下)[，,、]?|读(?:完|了一下)[，,、]?)/u;
const FILLER_PREFIX3 =
  /^(?:让我(?:先|来)?|我来(?:先|帮)?|我先|正在(?:查|看|读|翻|对照|检索|搜索|分析|梳理|整理|思考)|稍等[，,、]?|我需要(?:先|来)?(?:查|看|读|翻)[，,、]?)/u;
const FILLER_MID = /[，,](?:也就是说|简单来说|总的来说|换句话说|总结来说|分析下来)[，,]/gu;

/** Sentence sounds like process/thinking, not answer content. */
export const SPOKEN_PROCESS_SENTENCE =
  /^(?:让我|我来|我先|正在|稍等|我需要|我来帮|查(?:一下|完|阅|阅完|阅了一下)|看(?:一下|完|了一下)|读(?:一下|完|了一下)|翻(?:一下|完|了)|对照(?:一下|完|了)|检索|搜索|分析(?:完|一下|下来|之后)|梳理|理解(?:一下|之后)|整理|思考|想想|总结(?:来说|一下)|归纳(?:一下|来说)|综上|也就是说|关于(?:你问的|这个)?问题|你问(?:的)?|根据.{0,28}(?:来看|来说|可知)|从.{0,28}(?:来看|可知)|我认为|我的理解)/u;

export function isSpokenProcessSentence(sentence) {
  const p = String(sentence || "").trim();
  if (!p) return true;
  const stripped = stripSpokenFiller(p);
  return (
    SPOKEN_PROCESS_SENTENCE.test(p) ||
    (stripped !== p && SPOKEN_PROCESS_SENTENCE.test(stripped)) ||
    SPOKEN_PROCESS_SENTENCE.test(stripped)
  );
}

/** Drop common spoken preamble before TTS. */
export function stripSpokenFiller(text) {
  let s = String(text || "").trim();
  if (!s) return s;
  for (let i = 0; i < 8; i += 1) {
    const next = s
      .replace(FILLER_PREFIX, "")
      .replace(FILLER_PREFIX2, "")
      .replace(FILLER_PREFIX3, "")
      .trim();
    if (next === s) break;
    s = next;
  }
  s = s.replace(FILLER_MID, "，");
  return s.trim();
}

export function speakableText(md) {
  return String(md || "")
    .replace(/```[\s\S]*?```/g, " ")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/__([^_]+)__/g, "$1")
    .replace(/^#+\s+/gm, "")
    .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
    .replace(/[*_>#]/g, "")
    .replace(/\s+/g, " ")
    .trim();
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
  onAudio,
  onDone,
  maxSpeakChars = 0,
  limitSpoken,
  /** `stream` = TTS while tokens arrive; `final` = one TTS after answer is trimmed */
  speakStrategy = "stream",
}) {
  let pending = "";
  let full = "";
  let engine = "local-progress";
  const speakQueue = [];
  let speaking = Promise.resolve();
  let spokenChars = 0;
  let capped = false;

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
      ? { speak: speakableText(pending), rest: "" }
      : takeSpeakable(speakableText(pending), maxSpeakChars ? 32 : 72);
    if (!chunk.speak) {
      pending = chunk.rest || pending;
      return;
    }
    pending = chunk.rest;
    let speak = capChunk(chunk.speak);
    if (maxSpeakChars) speak = stripSpokenFiller(speak);
    if (!speak) return;
    spokenChars += [...speak].length;
    speakQueue.push(speak);
    speaking = speaking.then(async () => {
      if (signal?.aborted) return;
      const audio = await tts(speak, signal);
      if (signal?.aborted || !audio) return;
      await onAudio?.(audio);
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
  } catch (err) {
    if (signal?.aborted) return { engine, answer: full, cancelled: true };
    throw err;
  }
  if (limitSpoken) full = limitSpoken(full);
  if (speakStrategy === "final" && !signal?.aborted) {
    const toSpeak = limitSpoken
      ? full
      : stripSpokenFiller(speakableText(full));
    if (!String(toSpeak || "").trim()) {
      const err = new Error("没有可朗读的回答内容");
      err.code = "empty_answer";
      throw err;
    }
    await speakTextInParts({ text: toSpeak, tts, onAudio, signal });
  }
  if (!signal?.aborted) onDone?.({ text: full, engine, final: true });
  return { engine, answer: full, cancelled: Boolean(signal?.aborted) };
}
