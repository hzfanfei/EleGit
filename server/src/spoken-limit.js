import {
  isSpokenProcessSentence,
  speakableText,
  stripSpokenFiller,
} from "./voice-call.js";

/**
 * Keep substantive sentences only (drop thinking/process narration).
 */
export function spokenContentOnly(text) {
  const raw = speakableText(text);
  if (!raw) return raw;
  const parts =
    raw.match(/[^。！？!?]+[。！？!?]?/g)?.map((p) => p.trim()).filter(Boolean) ?? [raw];
  if (parts.length <= 1) return stripSpokenFiller(raw);
  const kept = parts
    .filter((p) => !isSpokenProcessSentence(p) && !META_SENTENCE.test(stripSpokenFiller(p)))
    .map(stripSpokenFiller)
    .filter(Boolean);
  let s;
  if (kept.length > 0) {
    s = kept.join("").trim();
  } else {
    s = stripSpokenFiller(parts[parts.length - 1]);
  }
  return stripSpokenFiller(s);
}

/** Default cap for book quick-voice replies (listen fatigue). */
export const BOOK_SPOKEN_MAX_CHARS = 48;
export const BOOK_SPOKEN_TARGET_CHARS = 35;

const META_SENTENCE =
  /^(?:用户(?:问|询问|提到)|你问(?:的)?|这个问题|该书|这本书|本文|这一节|本章(?:主要|讲|说))/u;

const END_PUNCT = /[。！？!?；;]$/;
const CUT_PUNCT = /[。！？!?；;，,、]/;

/**
 * Trim spoken Chinese for TTS; prefer cutting at punctuation, optional soft tail.
 */
export function limitSpokenChinese(
  text,
  { maxChars = BOOK_SPOKEN_MAX_CHARS, tail = "" } = {},
) {
  let s = spokenContentOnly(text);
  const chars = [...s];
  if (chars.length <= maxChars) return s;

  let cut = maxChars;
  const searchFrom = Math.min(maxChars, chars.length) - 1;
  const searchTo = Math.max(0, Math.floor(maxChars * 0.45));
  for (let i = searchFrom; i >= searchTo; i -= 1) {
    if (CUT_PUNCT.test(chars[i])) {
      cut = i + 1;
      break;
    }
  }
  s = chars.slice(0, cut).join("").trim();
  if (s && !END_PUNCT.test(s)) s += "。";
  const withTail = tail ? `${s}${tail}` : s;
  if (tail && [...withTail].length > maxChars + 8) return s;
  return withTail;
}
