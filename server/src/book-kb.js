import { readFile, stat } from "node:fs/promises";
import path from "node:path";
import { BOOK_DIRECT_ANSWER_RULES, BOOK_SPOKEN_ANSWER_RULES } from "./acp.js";
import { planBookPassages } from "./book-retrieve.js";
import { loadBookReadingManifest, safeChapterFilename } from "./books.js";
import { speakSummaryApiConfig, speakSummaryMessagesUrl, textFromMessagesResponse } from "./speak-summary.js";

const PASSAGE_SESSIONS = new Map();
const CHAPTER_CACHE = new Map();
const DEFAULT_PASSAGE_CHARS = 80_000;

export function bookKnowledgeSkip(code) {
  const err = new Error(code);
  err.code = "book_kb_skip";
  err.reason = code;
  return err;
}

export function bookPassageBudget(env = process.env) {
  const n = Number.parseInt(String(env.WENXIANG_BOOK_PASSAGE_CHARS || ""), 10);
  return Number.isFinite(n) && n > 2000 ? n : DEFAULT_PASSAGE_CHARS;
}

/** 问书固定走普通 MiniMax-M3，不用百万上下文那条。 */
export function bookKnowledgeModel(model) {
  const name = String(model || "").trim();
  if (!name || /minimax/i.test(name)) return "MiniMax-M3";
  return name;
}

export function bookKnowledgeConfig(settings) {
  const config = speakSummaryApiConfig(settings);
  if (!config) return null;
  return { ...config, model: bookKnowledgeModel(config.model) };
}

export function bookPriorPassages(sessionId) {
  return PASSAGE_SESSIONS.get(String(sessionId || "")) || [];
}

export function bookRememberPassages(sessionId, passages) {
  const id = String(sessionId || "").trim();
  if (!id) return;
  if (PASSAGE_SESSIONS.size > 50 && !PASSAGE_SESSIONS.has(id)) {
    const oldest = PASSAGE_SESSIONS.keys().next().value;
    PASSAGE_SESSIONS.delete(oldest);
  }
  PASSAGE_SESSIONS.set(id, (passages || []).map((ch) => ({
    file: ch.file,
    title: ch.title,
    text: ch.text,
  })));
}

export function resetBookKnowledgeState() {
  PASSAGE_SESSIONS.clear();
  CHAPTER_CACHE.clear();
}

export async function loadBookChapterTexts(materialized) {
  const readingPath = materialized?.readingPath || path.join(materialized.cacheDir, "reading.json");
  const info = await stat(readingPath);
  const sig = `${info.mtimeMs}:${info.size}`;
  const key = materialized.chaptersDir || path.join(materialized.cacheDir, "chapters");
  const hit = CHAPTER_CACHE.get(key);
  if (hit?.sig === sig) return hit.chapters;
  const manifest = await loadBookReadingManifest(materialized);
  const chapters = [];
  for (const item of manifest.chapters || []) {
    let file = "";
    try {
      file = safeChapterFilename(item?.file);
    } catch {
      continue;
    }
    let text = "";
    try {
      text = await readFile(path.join(key, file), "utf8");
    } catch {
      continue;
    }
    text = String(text || "").trim();
    if (!text) continue;
    chapters.push({ file, title: String(item?.title || file).trim() || file, text });
  }
  CHAPTER_CACHE.set(key, { sig, chapters });
  return chapters;
}

export function buildBookKnowledgeRequest({
  book,
  passages,
  question,
  history,
  spoken = false,
  model,
  cache = true,
}) {
  const rules = BOOK_DIRECT_ANSWER_RULES.filter((line) => !line.includes("TASK_COMPLETED"));
  if (spoken) rules.push(...BOOK_SPOKEN_ANSWER_RULES);
  rules.push(
    "只根据下面给出的章节原文回答。原文没有写到的情节、人物、对话不要编造。",
    "不要提文件名、路径，也不要说你在查阅。",
  );
  if (book?.title) rules.push(`书名：${book.title}`);
  if (book?.author) rules.push(`作者：${book.author}`);
  const passageText = (passages || [])
    .map((ch) => `【${ch.title}】\n${ch.text}`)
    .join("\n\n");
  const messages = [];
  for (const item of (history || []).slice(-8)) {
    if (!item?.content || (item.role !== "user" && item.role !== "assistant")) continue;
    messages.push({ role: item.role, content: String(item.content).slice(0, 2000) });
  }
  messages.push({ role: "user", content: String(question || "") });
  const bookBlock = { type: "text", text: passageText };
  if (cache) bookBlock.cache_control = { type: "ephemeral" };
  return {
    model,
    max_tokens: spoken ? 600 : 4096,
    stream: true,
    system: [
      { type: "text", text: rules.join("\n") },
      bookBlock,
    ],
    messages,
  };
}

export function textFromSseEvent(block) {
  const data = String(block || "")
    .split(/\r?\n/)
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice(5).trim())
    .join("\n");
  if (!data || data === "[DONE]") return "";
  let json;
  try {
    json = JSON.parse(data);
  } catch {
    return "";
  }
  if (json?.type === "error" || (json?.error && !json?.delta)) {
    const err = new Error(json?.error?.message || "模型接口失败");
    err.code = "book_kb_stream";
    throw err;
  }
  if (json?.delta?.type === "text_delta" && json.delta.text) return String(json.delta.text);
  const choice = json?.choices?.[0]?.delta?.content;
  return typeof choice === "string" ? choice : "";
}

export function createSseDeltaParser() {
  let buffer = "";
  return {
    push(chunk) {
      buffer += String(chunk || "");
      const parts = buffer.split(/\r?\n\r?\n/);
      buffer = parts.pop() || "";
      let text = "";
      for (const part of parts) text += textFromSseEvent(part);
      return text;
    },
    flush() {
      const text = buffer.trim() ? textFromSseEvent(buffer) : "";
      buffer = "";
      return text;
    },
  };
}

function anthropicHeaders(config) {
  const headers = {
    "content-type": "application/json",
    "anthropic-version": "2023-06-01",
  };
  if (config.auth === "bearer") {
    headers.authorization = `Bearer ${config.token}`;
    headers["x-api-key"] = config.token;
  } else {
    headers["x-api-key"] = config.token;
  }
  return headers;
}

async function readErrorBody(res) {
  try {
    return await res.text();
  } catch {
    return "";
  }
}

export async function* streamBookKnowledge({
  book,
  materialized,
  question,
  history,
  currentChapter,
  chapter,
  session,
  spoken = false,
  signal,
  config,
  settings,
  fetchImpl = fetch,
  loadChapters = loadBookChapterTexts,
  maxChars,
} = {}) {
  const raw = config || bookKnowledgeConfig(settings);
  if (!raw?.token || !raw?.base) throw bookKnowledgeSkip("unconfigured");
  const api = { ...raw, model: bookKnowledgeModel(raw.model) };
  let chapters = [];
  try {
    chapters = await loadChapters(materialized);
  } catch {
    throw bookKnowledgeSkip("no_chapters");
  }
  const sessionId = session?.id || "";
  const passages = planBookPassages({
    chapters,
    question,
    currentChapter: currentChapter || chapter,
    prior: bookPriorPassages(sessionId),
    maxChars: maxChars || bookPassageBudget(),
  });
  if (!passages.length) throw bookKnowledgeSkip("empty");
  bookRememberPassages(sessionId, passages);

  const url = speakSummaryMessagesUrl(api.base);
  const headers = anthropicHeaders(api);
  const post = async (cache) => fetchImpl(url, {
    method: "POST",
    headers,
    body: JSON.stringify(buildBookKnowledgeRequest({
      book,
      passages,
      question,
      history,
      spoken,
      model: api.model,
      cache,
    })),
    signal,
  });
  let res = await post(true);
  if (!res.ok && res.status === 400) {
    await readErrorBody(res);
    res = await post(false);
  }
  if (!res.ok) {
    await readErrorBody(res);
    const err = bookKnowledgeSkip("http");
    err.status = res.status;
    throw err;
  }

  let full = "";
  const pieces = [];
  const take = (text) => {
    if (!text) return;
    pieces.push(text);
    full += text;
  };
  const contentType = String(res.headers?.get?.("content-type") || "");
  if (contentType.includes("application/json") && !contentType.includes("text/event-stream")) {
    const json = await res.json();
    take(textFromMessagesResponse(json));
  } else {
    const reader = res.body?.getReader?.();
    if (!reader) throw bookKnowledgeSkip("no_stream");
    const decoder = new TextDecoder();
    const parser = createSseDeltaParser();
    const pull = (chunk) => {
      try {
        return parser.push(chunk);
      } catch (err) {
        if (!full) throw bookKnowledgeSkip("stream");
        throw err;
      }
    };
    while (true) {
      if (signal?.aborted) {
        await reader.cancel?.();
        return;
      }
      const step = await reader.read();
      if (step.done) break;
      take(pull(decoder.decode(step.value, { stream: true })));
      if (pieces.length === 1) break;
    }
    if (pieces.length) {
      yield { type: "start", engine: "book-kb" };
      yield { type: "status", phase: "generate", detail: "" };
      yield { type: "delta", text: pieces[0] };
      while (true) {
        if (signal?.aborted) {
          await reader.cancel?.();
          return;
        }
        const step = await reader.read();
        if (step.done) break;
        const text = pull(decoder.decode(step.value, { stream: true }));
        if (text) {
          full += text;
          yield { type: "delta", text };
        }
      }
      let tail = "";
      try {
        tail = parser.flush();
      } catch (err) {
        if (!full) throw bookKnowledgeSkip("stream");
        throw err;
      }
      if (tail) {
        full += tail;
        yield { type: "delta", text: tail };
      }
    }
  }
  if (!full.trim()) throw bookKnowledgeSkip("empty_answer");
  if (contentType.includes("application/json") && !contentType.includes("text/event-stream")) {
    yield { type: "start", engine: "book-kb" };
    yield { type: "status", phase: "generate", detail: "" };
    yield { type: "delta", text: full };
  }
  yield { type: "done", engine: "book-kb", answer: full, sessionId, model: api.model };
}

export async function* streamBookOrAgent({ knowledge, agent }) {
  let yielded = false;
  try {
    for await (const event of knowledge()) {
      yielded = true;
      yield event;
    }
    return;
  } catch (err) {
    if (yielded || err?.code !== "book_kb_skip") throw err;
  }
  yield* agent();
}
