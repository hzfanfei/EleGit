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
      assert.equal(published.length, 1);
      assert.equal(published[0].workspaceRoot, "C:/问象");
      assert.equal(published[0].notice.answer, "还在写的后半段");
      assert.equal(published[0].notice.sessionId, "s1");
      assert.equal(agent.killed, true);
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
