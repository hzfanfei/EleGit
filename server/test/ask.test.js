import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildCursorPrompt, detectCursorEngine, streamAnswer, streamText, synthesizeLocalAnswer } from "../src/ask.js";

const sampleProgress = {
  repo: {
    fullName: "acme/widget",
    defaultBranch: "main",
    pushedAt: "2026-09-14T10:00:00Z",
  },
  commits: [
    {
      sha: "abc1234",
      message: "Fix login timeout",
      author: "ada",
      date: "2026-09-14T09:00:00Z",
    },
  ],
  pulls: [{ number: 12, title: "Add tunnel status", user: "ada", draft: false }],
  issues: [{ number: 3, title: "Document PAT setup", user: "lin" }],
};

describe("synthesizeLocalAnswer", () => {
  it("uses real GitHub fields and never invents extra PRs", () => {
    const text = synthesizeLocalAnswer({
      question: "最近 PR 怎么样？",
      progress: sampleProgress,
    });
    assert.match(text, /acme\/widget/);
    assert.match(text, /#12 Add tunnel status/);
    assert.doesNotMatch(text, /#99/);
    assert.match(text, /GitHub API/);
  });

  it("mentions the local checkout path when present", () => {
    const text = synthesizeLocalAnswer({
      question: "README 里怎么启动？",
      progress: sampleProgress,
      local: {
        present: true,
        path: "/home/fei/问象/acme/widget",
        branch: "main",
        head: "abc1234",
        log: "abc1234 2026-09-14 ada Fix login timeout",
        files: ["README.md", "src/app.js"],
        readme: "# widget\nnpm start",
      },
    });
    assert.match(text, /问象\/acme\/widget/);
    assert.match(text, /npm start/);
    assert.match(text, /## /);
    assert.match(text, /^- /m);
    assert.doesNotMatch(text, /检出/);
  });

  it("says when there are no open PRs", () => {
    const text = synthesizeLocalAnswer({
      question: "有哪些 PR？",
      progress: { ...sampleProgress, pulls: [] },
    });
    assert.match(text, /没有开放的 Pull Request/);
  });
});

describe("streamText", () => {
  it("yields small chunks covering the full answer", async () => {
    const parts = [];
    for await (const piece of streamText("进度如何", { chunkSize: 2, delayMs: 0 })) {
      parts.push(piece);
    }
    assert.equal(parts.join(""), "进度如何");
    assert.ok(parts.length >= 2);
  });
});

describe("streamAnswer", () => {
  it("rechunks a large ACP delta before done so tokens appear progressively", async () => {
    const events = [];
    for await (const event of streamAnswer({
      question: "进度如何",
      progress: sampleProgress,
      context: "Repository: acme/widget",
      session: { id: "s1" },
      detectEngine: () => ({ id: "acp" }),
      streamOpts: { chunkSize: 2, delayMs: 0 },
      sessions: {
        prompt: async (_session, { onDelta }) => {
          onDelta("最近提交已经合进主干。");
        },
      },
    })) {
      events.push(event);
    }
    const deltas = events.filter((event) => event.type === "delta");
    assert.ok(deltas.length >= 4);
    assert.equal(deltas.map((event) => event.text).join(""), "最近提交已经合进主干。");
    assert.equal(events[0].type, "start");
    assert.equal(events.at(-1).type, "done");
    assert.ok(events.findIndex((event) => event.type === "delta") < events.findIndex((event) => event.type === "done"));
  });
});

describe("detectCursorEngine", () => {
  it("reports acp when a CLI exists, otherwise null", () => {
    const engine = detectCursorEngine();
    if (engine) {
      assert.equal(engine.id, "acp");
      assert.equal(engine.mode, "ask");
      assert.equal(engine.transport, "stdio");
    } else {
      assert.equal(engine, null);
    }
  });
});

describe("buildCursorPrompt", () => {
  it("embeds the question and forbids invention", () => {
    const prompt = buildCursorPrompt({
      question: "进度如何",
      history: [{ role: "user", content: "hi" }],
      context: "Repository: acme/widget",
    });
    assert.match(prompt, /Do not invent/);
    assert.match(prompt, /进度如何/);
    assert.match(prompt, /acme\/widget/);
  });
});
