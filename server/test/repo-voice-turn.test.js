import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { buildAcpPrompt } from "../src/acp.js";
import { createRepoAskIterator } from "../src/repo-voice-turn.js";

describe("repo voice turn", () => {
  it("spoken repo prompt includes voice-only rules", () => {
    const prompt = buildAcpPrompt({
      question: "最近提交讲了啥？",
      githubContext: "Repository: o/r",
      seedHistory: false,
      spokenAnswer: true,
    });
    assert.match(prompt, /语音朗读/);
    assert.match(prompt, /只输出答案正文/);
    assert.match(prompt, /最近提交讲了啥/);
  });

  it("createRepoAskIterator is an async generator factory", () => {
    const ask = createRepoAskIterator({
      progress: { repo: { fullName: "o/r" }, commits: [], pulls: [], issues: [] },
      context: "ctx",
      githubContext: "gh",
      local: { present: true, path: "/tmp/r" },
      session: { id: "s1", owner: "o", repo: "r", turns: 0 },
      sessions: {},
      history: [],
      signal: new AbortController().signal,
    });
    assert.equal(typeof ask, "function");
  });

  it("forwards agent mode into the spoken ask", async () => {
    let seen = false;
    const ask = createRepoAskIterator({
      progress: { repo: { fullName: "o/r" }, commits: [], pulls: [], issues: [] },
      context: "ctx",
      githubContext: "gh",
      local: { present: true, path: "/tmp/r" },
      session: { id: "s1", owner: "o", repo: "r", turns: 0 },
      sessions: {
        prompt: async (_session, opts) => {
          seen = opts.agentMode === true;
        },
      },
      history: [],
      signal: new AbortController().signal,
      agentMode: true,
    });
    const events = [];
    for await (const event of ask("把标题改掉")) events.push(event.type);
    assert.equal(seen, true);
    assert.equal(events[0], "start");
  });
});
