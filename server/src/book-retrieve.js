const STOP_TERMS = new Set([
  "什么", "怎么", "如何", "为何", "为什么", "一下", "这个", "那个", "是否", "可以",
  "我们", "你们", "他们", "她们", "一个", "不是", "就是", "还是", "以及", "因为",
  "所以", "如果", "但是", "然后", "已经", "正在", "这本书", "内容", "总结", "哪些",
  "哪个", "哪里", "请问", "告诉", "知道", "说说", "讲讲", "主要", "介绍", "帮我",
  "给我", "想问", "书里", "书中", "关于", "情节", "故事", "人物", "角色", "章节",
  "这章", "本章", "讲了", "讲的", "一下下", "总结一下",
]);

const SUMMARY_RE = /总结|概要|梗概|讲了什么|讲的什么|主要内容|全书|整个故事|主线|内容是什么|这本书的内容/;

const REASON_WEIGHT = { sample: 0, prior: 1, hit: 2, current: 3 };

export function isBookSummaryQuestion(question) {
  return SUMMARY_RE.test(String(question || ""));
}

export function questionTerms(question) {
  const terms = new Set();
  const text = String(question || "");
  for (const word of text.match(/[A-Za-z][A-Za-z0-9-]{1,}/g) || []) {
    terms.add(word.toLowerCase());
  }
  for (const span of text.match(/[\u4e00-\u9fff]{2,}/g) || []) {
    if (span.length <= 8 && !STOP_TERMS.has(span)) terms.add(span);
    if (span.length < 4) continue;
    for (const size of [2, 3]) {
      for (let i = 0; i <= span.length - size; i += 1) {
        const gram = span.slice(i, i + size);
        if (!STOP_TERMS.has(gram)) terms.add(gram);
      }
    }
  }
  return [...terms].slice(0, 48);
}

export function findCurrentChapter(chapters, currentChapter) {
  const name = String(currentChapter || "").trim();
  if (!name) return null;
  const list = chapters || [];
  const exact = list.find((ch) => ch?.title === name || ch?.file === name);
  if (exact) return exact;
  if (name.length < 2) return null;
  return list.find((ch) => {
    const title = String(ch?.title || "");
    return title.length >= 2 && (name.includes(title) || title.includes(name));
  }) || null;
}

function countTerm(text, term) {
  const needle = /[A-Za-z]/.test(term) ? term.toLowerCase() : term;
  const hay = needle === term ? text : text.toLowerCase();
  let count = 0;
  let from = 0;
  while (count < 8) {
    const at = hay.indexOf(needle, from);
    if (at < 0) break;
    count += 1;
    from = at + needle.length;
  }
  return count;
}

export function rankChapters(chapters, terms) {
  const useful = (terms || []).filter((term) => term && !STOP_TERMS.has(term) && term.length >= 2);
  const list = chapters || [];
  if (!useful.length || !list.length) return [];
  const n = list.length;
  const df = new Map();
  const counts = list.map((ch) => {
    const row = new Map();
    const text = String(ch?.text || "");
    for (const term of useful) {
      const hits = countTerm(text, term);
      row.set(term, hits);
      if (hits) df.set(term, (df.get(term) || 0) + 1);
    }
    return row;
  });
  const scored = list.map((ch, index) => {
    let score = 0;
    for (const term of useful) {
      const docs = df.get(term) || 0;
      if (docs > 1 && docs / n > 0.45) continue;
      const hits = counts[index].get(term) || 0;
      if (!hits) continue;
      const idf = Math.log((n + 1) / (docs + 1)) + 1;
      score += hits * idf * Math.min(term.length, 8);
    }
    return { ...ch, score };
  });
  return scored.filter((ch) => ch.score > 0).sort((a, b) => b.score - a.score);
}

function charLen(list) {
  return list.reduce((sum, ch) => sum + String(ch?.text || "").length, 0);
}

function trimPassages(list, maxChars) {
  const kept = list.map((ch) => ({ ...ch }));
  while (charLen(kept) > maxChars && kept.length > 1) {
    let drop = 0;
    for (let i = 1; i < kept.length; i += 1) {
      const next = REASON_WEIGHT[kept[i].reason] ?? 1;
      const best = REASON_WEIGHT[kept[drop].reason] ?? 1;
      if (next < best) drop = i;
    }
    if ((REASON_WEIGHT[kept[drop].reason] ?? 1) >= REASON_WEIGHT.current) break;
    kept.splice(drop, 1);
  }
  while (charLen(kept) > maxChars && kept.length > 1) {
    const drop = kept.findIndex((ch) => ch.reason !== "current");
    kept.splice(drop >= 0 ? drop : kept.length - 1, 1);
  }
  if (kept[0] && charLen(kept) > maxChars) {
    kept[0] = { ...kept[0], text: kept[0].text.slice(0, maxChars) };
  }
  return kept
    .filter((ch) => ch?.file && ch.text)
    .map(({ file, title, text }) => ({ file, title: title || file, text }));
}

/**
 * Chapters to send in one model call.
 * Prior passages stay in front so a follow-up can reuse the same prefix.
 * Summary questions also sample chapters across the book.
 */
export function planBookPassages({
  chapters,
  question,
  currentChapter,
  prior = [],
  maxChars = 80_000,
}) {
  const list = (chapters || []).filter((ch) => ch?.file && ch?.text);
  const summary = isBookSummaryQuestion(question);
  const ranked = rankChapters(list, questionTerms(question));
  const tagged = [];
  const push = (ch, reason) => {
    if (!ch?.file || !ch.text) return;
    const existing = tagged.find((item) => item.file === ch.file);
    if (existing) {
      if ((REASON_WEIGHT[reason] ?? 0) > (REASON_WEIGHT[existing.reason] ?? 0)) {
        existing.reason = reason;
      }
      return;
    }
    tagged.push({ file: ch.file, title: ch.title || ch.file, text: ch.text, reason });
  };
  for (const ch of prior) push(ch, "prior");
  push(findCurrentChapter(list, currentChapter), "current");
  if (summary && list.length) {
    const slots = Math.min(8, list.length);
    for (let i = 0; i < slots; i += 1) {
      const index = Math.round((i * (list.length - 1)) / Math.max(slots - 1, 1));
      push(list[index], "sample");
    }
  }
  for (const hit of ranked.slice(0, summary ? 4 : 3)) push(hit, "hit");
  const stable = [];
  for (const ch of prior) {
    const found = tagged.find((item) => item.file === ch.file);
    if (found && !stable.some((item) => item.file === found.file)) stable.push(found);
  }
  for (const reason of ["current", "sample", "hit"]) {
    for (const ch of tagged) {
      if (ch.reason === reason && !stable.some((item) => item.file === ch.file)) stable.push(ch);
    }
  }
  return trimPassages(stable, maxChars);
}
