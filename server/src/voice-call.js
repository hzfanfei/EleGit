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

export function takeSpeakable(buffer) {
  const text = String(buffer || "");
  let last = -1;
  for (let i = 0; i < text.length; i += 1) {
    if (SPEAK_PUNCT.test(text[i])) last = i;
  }
  if (last >= 0) {
    return { speak: text.slice(0, last + 1).trim(), rest: text.slice(last + 1) };
  }
  if (text.length >= 72) {
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
}) {
  let pending = "";
  let full = "";
  let engine = "local-progress";
  const speakQueue = [];
  let speaking = Promise.resolve();

  const flush = (force = false) => {
    const chunk = force
      ? { speak: speakableText(pending), rest: "" }
      : takeSpeakable(speakableText(pending));
    if (!chunk.speak) {
      pending = chunk.rest || pending;
      return;
    }
    pending = chunk.rest;
    speakQueue.push(chunk.speak);
    speaking = speaking.then(async () => {
      if (signal?.aborted) return;
      const audio = await tts(chunk.speak, signal);
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
  if (!signal?.aborted) flush(true);
  try {
    await speaking;
  } catch (err) {
    if (signal?.aborted) return { engine, answer: full, cancelled: true };
    throw err;
  }
  if (!signal?.aborted) onDone?.({ text: full, engine, final: true });
  return { engine, answer: full, cancelled: Boolean(signal?.aborted) };
}
