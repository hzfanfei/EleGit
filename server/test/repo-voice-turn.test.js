import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, it } from "node:test";
import { buildAcpPrompt, detectCursorEngine } from "../src/acp.js";
import { createRepoAskIterator, resolveRepoChatRuntime } from "../src/repo-voice-turn.js";

function git(args, cwd) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "git failed");
  }
}

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

  it("resolveRepoChatRuntime does not await warmRepo when checkout present", async () => {
    const workspace = await mkdtemp(join(tmpdir(), "wx-repo-"));
    const owner = "acme";
    const repo = "widget";
    const dest = join(workspace, owner, repo);
    await mkdir(dest, { recursive: true });
    git(["init", "-b", "main"], dest);

    let warmCalls = 0;
    let warmDone = false;
    const sessions = {
      warmRepo: async () => {
        warmCalls += 1;
        await new Promise((r) => setTimeout(r, 400));
        warmDone = true;
      },
    };
    const checkoutRepo = async () => {
      throw new Error("checkoutRepo should not run when present");
    };

    const started = Date.now();
    const out = await resolveRepoChatRuntime({
      store: { config: { workspaceRoot: workspace } },
      owner,
      repo,
      sessions,
      signal: new AbortController().signal,
      checkoutRepo,
      githubToken: () => "",
    });
    const elapsed = Date.now() - started;

    assert.equal(out.dest, dest);
    assert.equal(out.local.present, true);
    assert.ok(elapsed < 250, `expected fast resolve, took ${elapsed}ms`);
    assert.equal(warmDone, false);
    if (detectCursorEngine()) {
      assert.equal(warmCalls, 1);
    } else {
      assert.equal(warmCalls, 0);
    }
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
});
