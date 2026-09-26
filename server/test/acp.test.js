import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import path from "node:path";
import { PassThrough } from "node:stream";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import {
  AcpChannel,
  DEFAULT_ACP_MODEL,
  acpModelId,
  acpPromptTimeoutMs,
  claudeConfiguredModel,
  acpActivityLabelFromFsRead,
  acpActivityLabelFromUpdate,
  pushAcpToolActivity,
  acpVisibleTextFromUpdate,
  applyAcpEnginePreference,
  acpEnginePreference,
  setAcpEnginePreferences,
  sanitizeAcpUserVisibleText,
  buildAcpPrompt,
  buildBookAcpPrompt,
  createSessionStore,
  sanitizeAcpEngine,
  pickCursorVersionName,
  claudeCodeSessionOptions,
  preferredAcpModeIds,
  selectPermissionOption,
} from "../src/acp.js";
import { whichSync } from "../src/which.js";

const fakeAcp = path.join(path.dirname(fileURLToPath(import.meta.url)), "fixtures", "fake-acp.js");

describe("pickCursorVersionName", () => {
  it("uses the newest dated build and skips names the launcher ignores", () => {
    assert.equal(
      pickCursorVersionName([
        "2026.05.24-dda726e",
        "2026.06.19-20-24-33-653a7fb",
        "2026.04.30-4edb302",
      ]),
      "2026.05.24-dda726e",
    );
  });
});

describe("sanitizeAcpEngine", () => {
  it("accepts claude and cursor only", () => {
    assert.equal(sanitizeAcpEngine("claude"), "claude");
    assert.equal(sanitizeAcpEngine("Cursor"), "cursor");
    assert.equal(sanitizeAcpEngine("other"), null);
    assert.equal(applyAcpEnginePreference("cursor"), "cursor");
    assert.equal(process.env.WENXIANG_ACP_ENGINE, "cursor");
    applyAcpEnginePreference("claude");
  });
});

describe("setAcpEnginePreferences", () => {
  it("keeps book and repo engines independent", () => {
    setAcpEnginePreferences({ book: "cursor", repo: "claude" });
    assert.equal(acpEnginePreference("book"), "cursor");
    assert.equal(acpEnginePreference("repo"), "claude");
    setAcpEnginePreferences({ book: "claude", repo: "claude" });
  });
});

describe("claudeCodeSessionOptions", () => {
  it("keeps user settings and turns superpowers off", () => {
    const options = claudeCodeSessionOptions("MiniMax-M3");
    assert.deepEqual(options.settingSources, ["user"]);
    assert.equal(options.settings.enabledPlugins["superpowers@claude-plugins-official"], false);
    assert.equal(options.permissionMode, "ask");
  });
});

describe("acpPromptTimeoutMs", () => {
  it("defaults to 15 minutes", () => {
    assert.equal(acpPromptTimeoutMs({}), 15 * 60 * 1000);
    assert.equal(acpPromptTimeoutMs({ WENXIANG_ACP_PROMPT_TIMEOUT_MS: "600000" }), 600_000);
  });
});

describe("acpModelId", () => {
  it("follows the Claude settings model", () => {
    const prevEngine = process.env.WENXIANG_ACP_ENGINE;
    const prevClaude = process.env.WENXIANG_CLAUDE_MODEL;
    const prevAcpModel = process.env.WENXIANG_ACP_MODEL;
    delete process.env.WENXIANG_CLAUDE_MODEL;
    delete process.env.WENXIANG_ACP_MODEL;
    process.env.WENXIANG_ACP_ENGINE = "claude";
    const settings = { env: { ANTHROPIC_MODEL: "mimo-v2.6-flash", ANTHROPIC_AUTH_TOKEN: "secret" } };
    try {
      assert.equal(claudeConfiguredModel(settings), "mimo-v2.6-flash");
      assert.equal(acpModelId(process.env, settings), "mimo-v2.6-flash");
      process.env.WENXIANG_CLAUDE_MODEL = "MiniMax-M3";
      assert.equal(acpModelId(process.env, settings), "MiniMax-M3");
    } finally {
      if (prevEngine !== undefined) process.env.WENXIANG_ACP_ENGINE = prevEngine;
      else delete process.env.WENXIANG_ACP_ENGINE;
      if (prevClaude !== undefined) process.env.WENXIANG_CLAUDE_MODEL = prevClaude;
      else delete process.env.WENXIANG_CLAUDE_MODEL;
      if (prevAcpModel !== undefined) process.env.WENXIANG_ACP_MODEL = prevAcpModel;
      else delete process.env.WENXIANG_ACP_MODEL;
    }
  });

  it("defaults to grok-4.7-high-fast for cursor engine", () => {
    const prev = process.env.WENXIANG_CURSOR_MODEL;
    const prev2 = process.env.CURSOR_MODEL;
    const prevEngine = process.env.WENXIANG_ACP_ENGINE;
    const prevAcpModel = process.env.WENXIANG_ACP_MODEL;
    delete process.env.WENXIANG_CURSOR_MODEL;
    delete process.env.CURSOR_MODEL;
    delete process.env.WENXIANG_ACP_MODEL;
    process.env.WENXIANG_ACP_ENGINE = "cursor";
    try {
      assert.equal(acpModelId(), "grok-4.7-high-fast");
      assert.equal(DEFAULT_ACP_MODEL, "grok-4.7-high-fast");
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

describe("preferredAcpModeIds", () => {
  it("picks each engine's write mode first and never a write mode for read", () => {
    assert.deepEqual(preferredAcpModeIds(true, true), ["bypassPermissions", "acceptEdits"]);
    assert.equal(preferredAcpModeIds(true, false)[0], "agent");
    for (const claude of [true, false]) {
      const read = preferredAcpModeIds(false, claude);
      assert.deepEqual(read, ["ask"]);
      assert.equal(read.includes("plan"), false);
      assert.equal(read.some((id) => /dontAsk|bypass|agent|accept/i.test(id)), false);
    }
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

  it("agent mode allows every tool, preferring allow-always", () => {
    const options = [
      { optionId: "allow-once" },
      { optionId: "allow-always" },
      { optionId: "reject-once" },
    ];
    assert.equal(
      selectPermissionOption(
        { toolCall: { kind: "edit", title: "Write file" }, options },
        { agentMode: true },
      ),
      "allow-always",
    );
    assert.equal(
      selectPermissionOption(
        { toolCall: { kind: "delete", title: "Remove file" }, options: [{ optionId: "allow-once" }, { optionId: "reject-once" }] },
        { agentMode: true },
      ),
      "allow-once",
    );
    assert.equal(
      selectPermissionOption(
        { toolCall: { kind: "edit", title: "Write file" }, options: [{ optionId: "reject-once" }] },
        { agentMode: true },
      ),
      "allow-always",
    );
  });
});

describe("acpActivityLabelFromUpdate", () => {
  it("describes tool and read activity without leaking thought text", () => {
    assert.equal(
      acpActivityLabelFromUpdate({
        sessionUpdate: "tool_call_update",
        toolCall: { title: "Grep", kind: "search" },
      }),
      "搜索·Grep",
    );
    assert.equal(
      acpActivityLabelFromUpdate({
        sessionUpdate: "tool_call",
        title: "Read chat_page.dart",
        path: "app/lib/screens/chat_page.dart",
      }),
      "读·chat_page.dart",
    );
    assert.equal(
      acpActivityLabelFromUpdate({
        sessionUpdate: "tool_call_update",
      }),
      "",
    );
    assert.equal(
      acpActivityLabelFromUpdate({
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: "secret plan" },
      }),
      "",
    );
    assert.equal(acpActivityLabelFromFsRead("src/acp.js"), "读·acp.js");
  });
});

describe("pushAcpToolActivity", () => {
  it("shows the tool name, command, and a short output without reasoning", () => {
    const log = { items: [] };
    const started = pushAcpToolActivity(log, {
      sessionUpdate: "tool_call",
      toolCallId: "sh1",
      title: "Shell",
      kind: "execute",
      rawInput: { command: "npm test" },
    });
    assert.match(started, /Shell/);
    assert.match(started, /npm test/);

    const done = pushAcpToolActivity(log, {
      sessionUpdate: "tool_call_update",
      toolCallId: "sh1",
      status: "completed",
      rawOutput: { exitCode: 0, stdout: "3 passed\nsecond line\nthird line should drop" },
    });
    assert.match(done, /npm test/);
    assert.match(done, /3 passed/);
    assert.match(done, /second line/);
    assert.doesNotMatch(done, /third line/);
    assert.equal(log.items.length, 1);

    const searched = pushAcpToolActivity(log, {
      sessionUpdate: "tool_call",
      toolCallId: "g1",
      title: "Grep",
      kind: "search",
      rawInput: { pattern: "acpActivity", path: "server/src/acp.js" },
    });
    assert.match(searched, /Grep/);
    assert.match(searched, /acpActivity/);
    const counted = pushAcpToolActivity(log, {
      sessionUpdate: "tool_call_update",
      toolCallId: "g1",
      rawOutput: { totalMatches: 4 },
    });
    assert.match(counted, /4 处/);

    assert.equal(
      pushAcpToolActivity(log, {
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: "secret plan" },
      }),
      "",
    );
    assert.doesNotMatch(counted, /secret plan/);
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

  it("drops Claude Code auto-mode billing notices", () => {
    const notice =
      "We're changing auto mode to no longer charge for classifier requests in Claude Code. " +
      "However, this session isn't eligible because your requests go through api.minimaxi.com. " +
      "To fix it and access the new version of auto mode, ask your gateway to implement: " +
      "https://code.claude.com/docs/en/auto-mode-classifier-billing";
    assert.equal(sanitizeAcpUserVisibleText(notice), "");
    assert.equal(
      acpVisibleTextFromUpdate({
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: notice },
      }),
      "",
    );
    assert.equal(
      sanitizeAcpUserVisibleText("正文。\n\nWe're changing auto mode to no longer charge for classifier requests."),
      "正文。",
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
    assert.match(repo, /ask mode/);
    const agent = buildAcpPrompt({
      question: "把 README 标题改掉",
      agentMode: true,
    });
    assert.match(agent, /agent mode/);
    assert.doesNotMatch(agent, /Do not edit files/);
    const downloads = buildAcpPrompt({
      question: "把安装包发到手机",
      agentMode: true,
      staticFiles: {
        dir: "C:\\问象\\static",
        linkTemplate: "https://example.ngrok.dev/files/<path>?token=abc",
      },
    });
    assert.match(downloads, /C:\\问象\\static/);
    assert.match(downloads, /files\/<path>\?token=abc/);
    assert.match(downloads, /Do not put secrets/);
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

  it("warms one ACP process per phone chat", async () => {
    let spawns = 0;
    const store = createSessionStore({
      resolveCommand: () => ({
        id: "acp",
        path: process.execPath,
        args: [fakeAcp],
        mode: "ask",
        transport: "stdio",
      }),
      spawnImpl: (file, args, opts) => {
        spawns += 1;
        return spawn(file, args, opts);
      },
    });
    const cwd = process.cwd();
    const first = store.resolveForChat("hzfanfei", "fwechat", "");
    await store.prompt(first, {
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
    assert.equal(spawns, 2);
    await store.prompt(first, {
      question: "third",
      history: [],
      githubContext: "",
      cwd,
      onDelta: () => {},
    });
    assert.equal(spawns, 2);
    await store.close("hzfanfei", "fwechat", first.id);
    await store.close("hzfanfei", "fwechat", other.id);
  });

  it("starts a new channel after an engine switch, even if the old warm finishes late", async () => {
    let engine = "claude";
    let held = null;
    const store = createSessionStore({
      resolveCommand: () => ({
        id: engine,
        provider: engine,
        path: process.execPath,
        args: [fakeAcp],
        mode: "ask",
        transport: "stdio",
      }),
      spawnImpl: (file, args, opts) => {
        const child = spawn(file, args, opts);
        if (!held) {
          const stdout = child.stdout;
          const gate = new PassThrough();
          child.stdout = gate;
          held = () => stdout.pipe(gate);
        }
        return child;
      },
    });
    const cwd = process.cwd();
    store.resolveForChat("hzfanfei", "fwechat", "");
    const firstWarm = store.warmRepo("hzfanfei", "fwechat", cwd);
    await new Promise((resolve) => setTimeout(resolve, 30));
    engine = "cursor";
    await store.resetAllChannels();
    held?.();
    await firstWarm.catch(() => {});
    const second = await store.warmRepo("hzfanfei", "fwechat", cwd);
    assert.equal(second.reused, false);
    assert.equal(second.warmed, true);
    await store.resetAllChannels();
  });

  it("reseeds prior chat when the Claude process is recreated", async () => {
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
    const history = [
      { role: "user", content: "仓库叫什么" },
      { role: "assistant", content: "fwechat" },
    ];
    const session = store.resolveForChat("hzfanfei", "fwechat", "");
    const first = [];
    await store.prompt(session, {
      question: "第一问",
      history,
      githubContext: "Repository: hzfanfei/fwechat",
      cwd,
      onDelta: (text) => first.push(text),
    });
    assert.match(first.join(""), /seeded/);
    assert.match(first.join(""), /persona:/);

    const second = [];
    await store.prompt(session, {
      question: "第二问",
      history: [
        ...history,
        { role: "user", content: "第一问" },
        { role: "assistant", content: "答过了" },
      ],
      githubContext: "Repository: hzfanfei/fwechat",
      cwd,
      onDelta: (text) => second.push(text),
    });
    assert.match(second.join(""), /followup/);
    assert.doesNotMatch(second.join(""), /seeded/);
    assert.doesNotMatch(second.join(""), /persona:/);

    await store.resetAllChannels();
    const restored = [];
    await store.prompt(session, {
      question: "重启后再问",
      history: [
        ...history,
        { role: "user", content: "第一问" },
        { role: "assistant", content: "答过了" },
      ],
      githubContext: "Repository: hzfanfei/fwechat",
      cwd,
      onDelta: (text) => restored.push(text),
    });
    assert.match(restored.join(""), /seeded/);
    assert.match(restored.join(""), /persona:/);
    await store.resetAllChannels();
  });

  it("waits for the phone to answer ask_question", async () => {
    const store = createSessionStore({
      resolveCommand: () => ({
        id: "acp",
        path: process.execPath,
        args: [fakeAcp],
        mode: "ask",
        transport: "stdio",
      }),
      spawnImpl: (file, args, opts) =>
        spawn(file, args, {
          ...opts,
          env: { ...opts.env, FAKE_ACP_ASK: "1" },
        }),
    });
    const cwd = process.cwd();
    const session = store.resolveForChat("hzfanfei", "fwechat", "");
    const chunks = [];
    await store.prompt(session, {
      question: "请选择方案",
      history: [],
      cwd,
      onDelta: (text) => chunks.push(text),
      onInteraction: (event) => {
        assert.equal(event.kind, "ask");
        assert.equal(event.questions[0].id, "q1");
        assert.equal(
          store.answerInteraction(session.id, event.requestId, {
            kind: "ask",
            answers: [{ questionId: "q1", selectedOptionIds: ["a"] }],
          }),
          true,
        );
      },
    });
    assert.match(chunks.join(""), /first:1/);
    await store.resetAllChannels();
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

  it("does not close the channel while a prompt is still running", async () => {
    const channel = new AcpChannel({
      command: { path: process.execPath, args: [fakeAcp] },
      cwd: process.cwd(),
      spawnImpl: (file, args, opts) =>
        spawn(file, args, {
          ...opts,
          env: { ...opts.env, FAKE_ACP_PROMPT_DELAY_MS: "160" },
        }),
      idleMs: 40,
    });
    try {
      await channel.start();
      const pending = channel.prompt("slow question");
      await new Promise((resolve) => setTimeout(resolve, 80));
      assert.equal(channel.alive, true);
      await pending;
      assert.equal(channel.alive, true);
      await new Promise((resolve) => setTimeout(resolve, 80));
      assert.equal(channel.alive, false);
    } finally {
      await channel.close();
    }
  });
});
