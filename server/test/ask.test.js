import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildCursorPrompt, synthesizeLocalAnswer } from "../src/ask.js";

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

  it("says when there are no open PRs", () => {
    const text = synthesizeLocalAnswer({
      question: "有哪些 PR？",
      progress: { ...sampleProgress, pulls: [] },
    });
    assert.match(text, /没有开放的 Pull Request/);
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
