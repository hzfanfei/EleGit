import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  findCurrentChapter,
  isBookSummaryQuestion,
  planBookPassages,
  questionTerms,
  rankChapters,
} from "../src/book-retrieve.js";
import {
  bookKnowledgeModel,
  bookRememberPassages,
  buildBookKnowledgeRequest,
  createSseDeltaParser,
  resetBookKnowledgeState,
  streamBookKnowledge,
  streamBookOrAgent,
  textFromSseEvent,
} from "../src/book-kb.js";

function chapter(file, title, text) {
  return { file, title, text };
}

describe("book retrieval", () => {
  const chapters = [
    chapter("001-a.md", "1", "开头只写了雪。"),
    chapter("002-b.md", "2", "普通人的一天。"),
    chapter("003-c.md", "3", "桐原亮司在夜里出门。"),
    chapter("004-d.md", "4", "雪穗走在明处。"),
    chapter("005-e.md", "5", "结尾笹垣还在追。"),
  ];

  it("finds a name in the chapter that contains it", () => {
    const ranked = rankChapters(chapters, questionTerms("桐原亮司为什么出门"));
    assert.equal(ranked[0].file, "003-c.md");
    assert.equal(isBookSummaryQuestion("总结一下这本书的内容"), true);
    assert.equal(isBookSummaryQuestion("桐原亮司是谁"), false);
  });

  it("keeps the current chapter and puts earlier passages first", () => {
    const first = planBookPassages({
      chapters,
      question: "桐原亮司为什么出门",
      currentChapter: "4",
    });
    assert.equal(first.some((ch) => ch.file === "004-d.md"), true);
    assert.equal(first.some((ch) => ch.file === "003-c.md"), true);
    const second = planBookPassages({
      chapters,
      question: "雪穗在哪里",
      prior: first,
    });
    assert.equal(second[0].file, first[0].file);
    assert.equal(second.some((ch) => ch.file === "004-d.md"), true);
  });

  it("samples the whole book for a summary and can match the open chapter", () => {
    const picked = planBookPassages({
      chapters,
      question: "总结一下这本书的内容",
    });
    assert.equal(picked[0].file, "001-a.md");
    assert.equal(picked.some((ch) => ch.file === "005-e.md"), true);
    assert.equal(findCurrentChapter(chapters, "3")?.file, "003-c.md");
  });
});

describe("book knowledge call", () => {
  it("pins the book model to MiniMax-M3 and marks the passages cacheable", () => {
    assert.equal(bookKnowledgeModel("MiniMax-M3[1M]"), "MiniMax-M3");
    const body = buildBookKnowledgeRequest({
      book: { title: "白夜行", author: "东野圭吾" },
      passages: [{ file: "003-c.md", title: "3", text: "桐原亮司在夜里出门。" }],
      question: "他为什么出门？",
      history: [{ role: "user", content: "上一问" }, { role: "assistant", content: "上一答" }],
      model: "MiniMax-M3",
    });
    assert.equal(body.model, "MiniMax-M3");
    assert.equal(body.tools, undefined);
    assert.equal(body.system[1].cache_control.type, "ephemeral");
    assert.match(body.system[1].text, /桐原亮司在夜里出门/);
    assert.equal(body.messages.at(-1).content, "他为什么出门？");
  });

  it("reads a text delta out of an SSE block", () => {
    const parser = createSseDeltaParser();
    const chunk = [
      'event: content_block_delta',
      'data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"先想"}}',
      "",
      'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"亮司夜里出了门。"}}',
      "",
      "",
    ].join("\n");
    assert.equal(parser.push(chunk), "亮司夜里出了门。");
    assert.equal(textFromSseEvent('data: {"delta":{"type":"text_delta","text":"第二句。"}}'), "第二句。");
  });

  it("streams one answer and falls back when retrieval finds nothing", async () => {
    resetBookKnowledgeState();
    const seen = [];
    const events = [];
    for await (const event of streamBookKnowledge({
      book: { title: "白夜行" },
      question: "桐原亮司为什么出门",
      session: { id: "s1" },
      config: { model: "MiniMax-M3[1M]", base: "https://api.example/anthropic", token: "sk-test", auth: "bearer" },
      loadChapters: async () => [
        chapter("003-c.md", "3", "桐原亮司在夜里出门。"),
      ],
      fetchImpl: async (_url, init) => {
        seen.push(JSON.parse(init.body));
        const encoder = new TextEncoder();
        const payload = 'data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"他夜里出了门。"}}\n\n';
        return {
          ok: true,
          status: 200,
          headers: { get: () => "text/event-stream" },
          body: {
            getReader() {
              let sent = false;
              return {
                async read() {
                  if (sent) return { done: true, value: undefined };
                  sent = true;
                  return { done: false, value: encoder.encode(payload) };
                },
                async cancel() {},
              };
            },
          },
        };
      },
    })) {
      events.push(event);
    }
    assert.equal(seen[0].model, "MiniMax-M3");
    assert.equal(events.at(-1).answer, "他夜里出了门。");
    assert.equal(events.at(-1).engine, "book-kb");

    const fallback = [];
    for await (const event of streamBookOrAgent({
      knowledge: () => streamBookKnowledge({
        question: "今天天气",
        config: { model: "MiniMax-M3", base: "https://api.example", token: "sk-test", auth: "api-key" },
        loadChapters: async () => [chapter("001-a.md", "1", "只有雪。")],
        fetchImpl: async () => { throw new Error("should not be called"); },
      }),
      agent: async function* agent() {
        yield { type: "done", engine: "acp", answer: "改由助手翻书。" };
      },
    })) {
      fallback.push(event);
    }
    assert.equal(fallback[0].engine, "acp");
    bookRememberPassages("s1", []);
    resetBookKnowledgeState();
  });
});
