import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import {
  AcpChannel,
  DEFAULT_ACP_MODEL,
  acpModelId,
  acpVisibleTextFromUpdate,
  buildAcpPrompt,
  buildBookAcpPrompt,
  createSessionStore,
  selectPermissionOption,
} from "../src/acp.js";
import { whichSync } from "../src/which.js";

const fakeAcp = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-acp.js");

describe("acpModelId", () => {
  it("defaults to composer-2.5-fast for cursor engine", () => {
    const prev = process.env.WENXIANG_CURSOR_MODEL;
    const prev2 = process.env.CURSOR_MODEL;
    const prevEngine = process.env.WENXIANG_ACP_ENGINE;
    const prevAcpModel = process.env.WENXIANG_ACP_MODEL;
    delete process.env.WENXIANG_CURSOR_MODEL;
    delete process.env.CURSOR_MODEL;
    delete process.env.WENXIANG_ACP_MODEL;
    process.env.WENXIANG_ACP_ENGINE = "cursor";
    try {
      assert.equal(acpModelId(), "composer-2.5-fast");
      assert.equal(DEFAULT_ACP_MODEL, "composer-2.5-fast");
    } finally {
      if (prev !== undefined) process.env.WENXIANG_CURSOR_MODEL = prev;
      if (prev2 !== undefined) process.env.CURSOR_MODEL = prev2;
      if (prevEngine !== undefined) process.env.WENXIANG_ACP_ENGINE = prevEngine;
      else delete process.env.WENXIANG_ACP_ENGINE;
      if (prevAcpModel !== undefined) process.env.WENXIANG_ACP_MODEL = prevAcpModel;
    }
  });
});

describe("whichSync", () => {
  it("resolves node from PATH on this machine", () => {
    const found = whichSync("node");
    assert.ok(found);
    assert.match(found, /node/i);
  });
});

describe("selectPermissionOption", () => {
  it("rejects write/edit tools and allows reads", () => {
    const options = [
      { optionId: "allow-once" },
      { optionId: "reject-once" },
    ];
    assert.equal(
      selectPermissionOption({ toolCall: { kind: "edit", title: "Write file" }, options }),
      "reject-once",
    );
    assert.equal(
      selectPermissionOption({ toolCall: { kind: "read", title: "Read file" }, options }),
      "allow-once",
    );
  });
});

describe("acpVisibleTextFromUpdate", () => {
  it("forwards agent answer chunks only, not reasoning", () => {
    assert.equal(
      acpVisibleTextFromUpdate({
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "答案" },
      }),
      "答案",
    );
    assert.equal(
      acpVisibleTextFromUpdate({
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: "正在读 INDEX" },
      }),
      "",
    );
    assert.equal(
      acpVisibleTextFromUpdate({
        sessionUpdate: "agent_message",
        content: [{ type: "text", text: "整段" }],
      }),
      "整段",
    );
  });
});

describe("buildBookAcpPrompt", () => {
  it("includes book context and question", () => {
    const prompt = buildBookAcpPrompt({
      question: "主角是谁？",
      bookContext: "Book title: 样例书\nUnpacked EPUB directory: /tmp/book",
      seedHistory: false,
    });
    assert.match(prompt, /问象·问书/);
    assert.match(prompt, /样例书/);
    assert.match(prompt, /主角是谁/);
    assert.match(prompt, /本题作答/);
  });

  it("does not tell the agent how to search files", () => {
    const book = buildBookAcpPrompt({
      question: "这本书讲啥",
      bookContext: "Book title: 样例书",
      currentChapter: "第三章",
    });
    assert.doesNotMatch(book, /read INDEX\.md/i);
    assert.doesNotMatch(book, /open the matching file/i);
    assert.doesNotMatch(book, /chapters\/\*\.md, then answer/i);
    const repo = buildAcpPrompt({
      question: "最近在做什么",
      githubContext: "Repository: hzfanfei/fwechat",
    });
    assert.doesNotMatch(repo, /read the checkout and answer/i);
  });
});

describe("buildAcpPrompt", () => {
  it("seeds history only when reconnecting", () => {
    const history = [
      { role: "user", content: "仓库叫什么" },
      { role: "assistant", content: "fwechat" },
    ];
    const seeded = buildAcpPrompt({
      question: "再说一遍",
      history,
      githubContext: "Repository: hzfanfei/fwechat",
      seedHistory: true,
    });
    assert.match(seeded, /Prior conversation/);
    assert.match(seeded, /fwechat/);
    const live = buildAcpPrompt({
      question: "再说一遍",
      history,
      githubContext: "Repository: hzfanfei/fwechat",
      seedHistory: false,
    });
    assert.doesNotMatch(live, /Prior conversation/);
    assert.match(live, /再说一遍/);
  });
});

describe("session store", () => {
  it("creates, lists, switches implicit chat, and closes without reuse", async () => {
    const store = createSessionStore({
      resolveCommand: () => ({
        id: "acp",
        path: process.execPath,
        args: [fakeAcp],
        mode: "ask",
        transport: "stdio",
      }),
      spawnImpl: spawn,
    });
    const first = store.create("hzfanfei", "fwechat");
    assert.equal(first.title, "新会话");
    assert.equal(first.active, true);
    const listed = store.list("hzfanfei", "fwechat");
    assert.equal(listed.sessions.length, 1);
    assert.equal(listed.activeSessionId, first.id);

    const implicit = store.resolveForChat("hzfanfei", "fwechat", "");
    assert.equal(implicit.id, first.id);

    const second = store.create("hzfanfei", "fwechat");
    assert.equal(store.list("hzfanfei", "fwechat").activeSessionId, second.id);
    assert.notEqual(second.id, first.id);

    const closed = await store.close("hzfanfei", "fwechat", first.id);
    assert.equal(closed.closed, true);
    const recovered = store.resolveForChat("hzfanfei", "fwechat", first.id);
    assert.equal(recovered.id, second.id);
    assert.equal(store.resolveForChat("hzfanfei", "fwechat", second.id).id, second.id);
    const fresh = createSessionStore({
      resolveCommand: () => ({
        id: "acp",
        path: process.execPath,
        args: [fakeAcp],
        mode: "ask",
        transport: "stdio",
      }),
      spawnImpl: spawn,
    });
    const afterRestart = fresh.resolveForChat("hzfanfei", "fwechat", first.id);
    assert.ok(afterRestart.id);
    assert.notEqual(afterRestart.id, first.id);
  });

  it("warms a shared repo ACP channel across sessions", async () => {
    const store = createSessionStore({
      resolveCommand: () => ({
        id: "acp",
        path: process.execPath,
        args: [fakeAcp],
        mode: "ask",
        transport: "stdio",
      }),
      spawnImpl: spawn,
    });
    const cwd = process.cwd();
    const first = await store.warmRepo("hzfanfei", "fwechat", cwd);
    assert.equal(first.warmed, true);
    assert.equal(first.reused, false);
    const second = await store.warmRepo("hzfanfei", "fwechat", cwd);
    assert.equal(second.warmed, true);
    assert.equal(second.reused, true);
    const session = store.resolveForChat("hzfanfei", "fwechat", "");
    await store.prompt(session, {
      question: "hello",
      history: [],
      githubContext: "",
      cwd,
      onDelta: () => {},
    });
    const other = store.create("hzfanfei", "fwechat");
    await store.prompt(store.resolveForChat("hzfanfei", "fwechat", other.id), {
      question: "again",
      history: [],
      githubContext: "",
      cwd,
      onDelta: () => {},
    });
    await store.close("hzfanfei", "fwechat", session.id);
    await store.close("hzfanfei", "fwechat", other.id);
  });
});

describe("AcpChannel", () => {
  it("handshakes, streams, and keeps the same ACP session for a follow-up", async () => {
    const channel = new AcpChannel({
      command: { path: process.execPath, args: [fakeAcp] },
      cwd: process.cwd(),
      spawnImpl: spawn,
      idleMs: 0,
    });
    const chunks = [];
    await channel.start();
    assert.equal(channel.sessionId, "fake-acp-session");
    await channel.prompt("first question", { onDelta: (t) => chunks.push(t) });
    await channel.prompt("follow up", { onDelta: (t) => chunks.push(t) });
    await channel.close();
    assert.deepEqual(chunks, ["first:1", "followup:2"]);
  });
});
