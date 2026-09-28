import assert from "node:assert/strict";
import net from "node:net";
import { once } from "node:events";
import { PassThrough } from "node:stream";
import { describe, it } from "node:test";
import { noteRelayTraffic, startTurnRelay } from "../src/turn-relay.js";

function fakeAgent() {
  const stdout = new PassThrough();
  const stdin = new PassThrough();
  const child = {
    stdout,
    stdin,
    stderr: new PassThrough(),
    pid: 42,
    killed: false,
    on() {
      return child;
    },
    kill() {
      child.killed = true;
    },
  };
  return child;
}

describe("noteRelayTraffic", () => {
  it("keeps assistant text and finishes on the prompt result", () => {
    let state = noteRelayTraffic(
      { answer: "", promptId: null, done: false },
      "in",
      JSON.stringify({ jsonrpc: "2.0", id: 7, method: "session/prompt", params: {} }),
    );
    state = noteRelayTraffic(
      state,
      "out",
      JSON.stringify({
        method: "session/update",
        params: {
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "后半段" },
          },
        },
      }),
    );
    assert.equal(state.answer, "后半段");
    assert.equal(state.done, false);
    state = noteRelayTraffic(
      state,
      "out",
      JSON.stringify({ jsonrpc: "2.0", id: 7, result: { stopReason: "end_turn" } }),
    );
    assert.equal(state.done, true);
  });
});

describe("turn relay", () => {
  it("publishes the finished answer after the companion socket is gone", async () => {
    const agent = fakeAgent();
    const published = [];
    const relay = await startTurnRelay({
      port: 0,
      spawnImpl: () => agent,
      publish: async (workspaceRoot, notice) => {
        published.push({ workspaceRoot, notice });
      },
    });
    try {
      const socket = net.connect(relay.port, "127.0.0.1");
      await once(socket, "connect");
      const lines = readlineLines(socket);
      socket.write(`${JSON.stringify({
        op: "spawn",
        key: "s1:1",
        file: "agent",
        args: [],
      })}\n`);
      const spawned = JSON.parse(await lines.next());
      assert.equal(spawned.op, "spawned");
      socket.write(`${JSON.stringify({
        op: "meta",
        key: "s1:1",
        meta: {
          workspaceRoot: "C:/问象",
          session: { id: "s1", owner: "octo", repo: "demo" },
          question: "进度如何",
        },
      })}\n`);
      socket.write(`${JSON.stringify({
        op: "stdin",
        key: "s1:1",
        data: `${JSON.stringify({ jsonrpc: "2.0", id: 7, method: "session/prompt", params: {} })}\n`,
      })}\n`);
      await new Promise((resolve) => setTimeout(resolve, 20));
      socket.end();
      await once(socket, "close");
      agent.stdout.write(`${JSON.stringify({
        method: "session/update",
        params: {
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "还在写的后半段" },
          },
        },
      })}\n`);
      agent.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: 7, result: { stopReason: "end_turn" } })}\n`);
      const deadline = Date.now() + 1000;
      while ((!published.length || !agent.killed) && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      assert.equal(published.at(-1).notice.answer, "还在写的后半段");
      assert.equal(published.at(-1).notice.sessionId, "s1");
      assert.notEqual(published.at(-1).notice.partial, true);
      assert.equal(agent.killed, true);
    } finally {
      relay.close();
    }
  });

  it("still publishes after the companion socket resets", async () => {
    const agent = fakeAgent();
    const published = [];
    const relay = await startTurnRelay({
      port: 0,
      spawnImpl: () => agent,
      publish: async (workspaceRoot, notice) => {
        published.push({ workspaceRoot, notice });
      },
    });
    try {
      const socket = net.connect(relay.port, "127.0.0.1");
      await once(socket, "connect");
      socket.write(`${JSON.stringify({
        op: "spawn",
        key: "s1:2",
        file: "agent",
        args: [],
      })}\n`);
      socket.write(`${JSON.stringify({
        op: "meta",
        key: "s1:2",
        meta: {
          workspaceRoot: "C:/问象",
          session: { id: "s1", owner: "octo", repo: "demo" },
          question: "进度如何",
        },
      })}\n`);
      socket.write(`${JSON.stringify({
        op: "stdin",
        key: "s1:2",
        data: `${JSON.stringify({ jsonrpc: "2.0", id: 7, method: "session/prompt", params: {} })}\n`,
      })}\n`);
      await new Promise((resolve) => setTimeout(resolve, 30));
      socket.on("error", () => {});
      socket.resetAndDestroy();
      await once(socket, "close");
      agent.stdout.write(`${JSON.stringify({
        method: "session/update",
        params: {
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "断线后的全文" },
          },
        },
      })}\n`);
      agent.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", id: 7, result: { stopReason: "end_turn" } })}\n`);
      const deadline = Date.now() + 1000;
      while (
        !published.some((row) => row.notice.partial !== true) &&
        Date.now() < deadline
      ) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      const last = published.at(-1);
      assert.equal(last.notice.answer, "断线后的全文");
      assert.notEqual(last.notice.partial, true);
    } finally {
      relay.close();
    }
  });

  it("publishes text already written before the prompt result", async () => {
    const agent = fakeAgent();
    const published = [];
    const relay = await startTurnRelay({
      port: 0,
      spawnImpl: () => agent,
      publish: async (workspaceRoot, notice) => {
        published.push({ workspaceRoot, notice });
      },
    });
    try {
      const socket = net.connect(relay.port, "127.0.0.1");
      await once(socket, "connect");
      socket.write(`${JSON.stringify({
        op: "spawn",
        key: "s1:3",
        file: "agent",
        args: [],
      })}\n`);
      socket.write(`${JSON.stringify({
        op: "meta",
        key: "s1:3",
        meta: {
          workspaceRoot: "C:/问象",
          session: { id: "s1", owner: "octo", repo: "demo" },
          question: "进度如何",
          partial: true,
        },
      })}\n`);
      socket.write(`${JSON.stringify({
        op: "stdin",
        key: "s1:3",
        data: `${JSON.stringify({ jsonrpc: "2.0", id: 7, method: "session/prompt", params: {} })}\n`,
      })}\n`);
      await new Promise((resolve) => setTimeout(resolve, 30));
      socket.on("error", () => {});
      socket.resetAndDestroy();
      await once(socket, "close");
      agent.stdout.write(`${JSON.stringify({
        method: "session/update",
        params: {
          update: {
            sessionUpdate: "agent_message_chunk",
            content: { type: "text", text: "先写到这里" },
          },
        },
      })}\n`);
      const deadline = Date.now() + 1000;
      while (!published.length && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 10));
      }
      assert.equal(published.length, 1);
      assert.equal(published[0].notice.partial, true);
      assert.equal(published[0].notice.answer, "先写到这里");
      assert.equal(agent.killed, false);
    } finally {
      relay.close();
    }
  });

  it("publishes thought and tool steps before any answer text", async () => {
    const agent = fakeAgent();
    const published = [];
    const relay = await startTurnRelay({
      port: 0,
      spawnImpl: () => agent,
      publish: async (_workspaceRoot, notice) => {
        published.push({ notice });
      },
    });
    try {
      const socket = net.connect(relay.port, "127.0.0.1");
      await once(socket, "connect");
      socket.write(`${JSON.stringify({
        op: "spawn",
        key: "s1:4",
        file: "agent",
        args: [],
      })}\n`);
      socket.write(`${JSON.stringify({
        op: "meta",
        key: "s1:4",
        meta: {
          workspaceRoot: "C:/问象",
          session: { id: "s1", owner: "octo", repo: "demo" },
          question: "进度如何",
          partial: true,
        },
      })}\n`);
      await new Promise((resolve) => setTimeout(resolve, 30));
      socket.on("error", () => {});
      socket.resetAndDestroy();
      await once(socket, "close");
      const step = (update) => `${JSON.stringify({ method: "session/update", params: { update } })}\n`;
      agent.stdout.write(step({
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: "先看回补" },
      }));
      agent.stdout.write(step({
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        title: "Read",
        kind: "read",
        locations: [{ path: "server/src/ask.js" }],
      }));
      const deadline = Date.now() + 1500;
      const ready = () => published.some((row) => {
        const activity = String(row.notice.activity || "");
        return activity.includes("思考") && activity.includes("读·ask.js");
      });
      while (!ready() && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      assert.equal(ready(), true);
      assert.equal(published.at(-1).notice.partial, true);
      assert.equal(agent.killed, false);
    } finally {
      relay.close();
    }
  });

  it("keeps the tool step on later answer text", async () => {
    const agent = fakeAgent();
    const published = [];
    const relay = await startTurnRelay({
      port: 0,
      spawnImpl: () => agent,
      publish: async (_workspaceRoot, notice) => {
        published.push(notice);
      },
    });
    try {
      const socket = net.connect(relay.port, "127.0.0.1");
      await once(socket, "connect");
      socket.write(`${JSON.stringify({ op: "spawn", key: "s1:5", file: "agent", args: [] })}\n`);
      socket.write(`${JSON.stringify({
        op: "meta",
        key: "s1:5",
        meta: {
          workspaceRoot: "C:/问象",
          session: { id: "s1", owner: "octo", repo: "demo" },
          question: "进度如何",
          partial: true,
        },
      })}\n`);
      await new Promise((resolve) => setTimeout(resolve, 30));
      socket.on("error", () => {});
      socket.resetAndDestroy();
      await once(socket, "close");
      const step = (update) => `${JSON.stringify({ method: "session/update", params: { update } })}\n`;
      agent.stdout.write(step({
        sessionUpdate: "tool_call",
        toolCallId: "t1",
        title: "Read",
        kind: "read",
        locations: [{ path: "server/src/ask.js" }],
      }));
      agent.stdout.write(step({
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "先说到这" },
      }));
      const deadline = Date.now() + 1500;
      const ready = () => published.some((notice) =>
        String(notice.activity || "").includes("读·ask.js") &&
        String(notice.answer || "").includes("先说到这"));
      while (!ready() && Date.now() < deadline) {
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
      assert.equal(ready(), true);
    } finally {
      relay.close();
    }
  });
});

function readlineLines(socket) {
  let buf = "";
  const lines = [];
  const waiters = [];
  function push(line) {
    const waiter = waiters.shift();
    if (waiter) waiter(line);
    else lines.push(line);
  }
  socket.setEncoding("utf8");
  socket.on("data", (chunk) => {
    buf += chunk;
    let idx = buf.indexOf("\n");
    while (idx >= 0) {
      push(buf.slice(0, idx));
      buf = buf.slice(idx + 1);
      idx = buf.indexOf("\n");
    }
  });
  return {
    next() {
      if (lines.length) return Promise.resolve(lines.shift());
      return new Promise((resolve) => waiters.push(resolve));
    },
    close() {},
  };
}
