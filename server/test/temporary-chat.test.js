import test from "node:test";
import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { mkdtemp, mkdir, rm, stat, utimes, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { cleanupAbandonedTemporaryChats, createTemporaryChats, TemporaryChat } from "../src/temporary-chat.js";

function fakeCodex({ ephemeral = true, autoComplete = true } = {}) {
  const requests = [];
  const child = new EventEmitter();
  child.stdin = new PassThrough();
  child.stdout = new PassThrough();
  child.stderr = new PassThrough();
  child.exitCode = null;
  child.kill = () => { child.exitCode = 0; child.emit("exit", 0); };
  let buffer = "";
  child.stdin.on("data", (chunk) => {
    buffer += chunk;
    const lines = buffer.split("\n");
    buffer = lines.pop();
    for (const line of lines) {
      const msg = JSON.parse(line);
      requests.push(msg);
      const send = (value) => child.stdout.write(`${JSON.stringify(value)}\n`);
      if (msg.method === "initialize") send({ id: msg.id, result: {} });
      if (msg.method === "thread/start") send({ id: msg.id, result: { thread: { id: "thread", ephemeral } } });
      if (msg.method === "turn/start") {
        send({ id: msg.id, result: { turn: { id: "turn" } } });
        send({ method: "item/started", params: { threadId: "thread", item: { type: "reasoning" } } });
        send({ method: "item/agentMessage/delta", params: { threadId: "thread", delta: "回答" } });
        if (autoComplete) send({ method: "turn/completed", params: { threadId: "thread", turn: { status: "completed" } } });
      }
      if (msg.method === "turn/interrupt") {
        send({ id: msg.id, result: {} });
        send({ method: "turn/completed", params: { threadId: "thread", turn: { status: "interrupted" } } });
      }
    }
  });
  return { child, requests };
}

test("临时线程复用本次上下文且不传其他会话", async () => {
  const fake = fakeCodex();
  const chat = new TemporaryChat({ executable: "fake", spawnImpl: () => fake.child });
  try {
    let answer = "";
    await chat.prompt("第一个问题", (text) => { answer += text; });
    await chat.prompt("追问", () => {});
    assert.equal(answer, "回答");
    const starts = fake.requests.filter((r) => r.method === "thread/start");
    assert.equal(starts.length, 1);
    assert.equal(starts[0].params.ephemeral, true);
    assert.equal(starts[0].params.config.project_doc_max_bytes, 0);
    assert.deepEqual(fake.requests.filter((r) => r.method === "turn/start").map((r) => r.params.input[0].text), ["第一个问题", "追问"]);
  } finally { await chat.close(); }
});

test("临时图片与进度只传给当前线程", async () => {
  const fake = fakeCodex();
  const chat = new TemporaryChat({ executable: "fake", spawnImpl: () => fake.child });
  try {
    const statuses = [];
    const image = "data:image/png;base64,aGVsbG8=";
    await chat.prompt("看图", () => {}, undefined, [image], (status) => statuses.push(status));
    const turn = fake.requests.find((r) => r.method === "turn/start");
    assert.deepEqual(turn.params.input, [{ type: "text", text: "看图", text_elements: [] }, { type: "image", url: image }]);
    assert.equal(turn.params.summary, "concise");
    assert.deepEqual(statuses, ["正在思考"]);
  } finally { await chat.close(); }
});

test("停止回答会中断当前线程", async () => {
  const fake = fakeCodex({ autoComplete: false });
  const chat = new TemporaryChat({ executable: "fake", spawnImpl: () => fake.child });
  try {
    const prompted = chat.prompt("请回答", () => {});
    prompted.catch(() => {});
    while (!chat.active?.turnId) await new Promise((resolve) => setTimeout(resolve, 1));
    await chat.interrupt();
    await assert.rejects(prompted, /已停止/);
    assert.equal(fake.requests.filter((r) => r.method === "turn/interrupt").length, 1);
  } finally { await chat.close(); }
});

test("底层未确认临时线程时拒绝发送问题", async () => {
  const fake = fakeCodex({ ephemeral: false });
  const chat = new TemporaryChat({ executable: "fake", spawnImpl: () => fake.child });
  try {
    await assert.rejects(chat.prompt("私密问题", () => {}), /未确认临时线程/);
    assert.equal(fake.requests.some((r) => r.method === "turn/start"), false);
  } finally { await chat.close(); }
});

test("关闭和超时均销毁会话，并且新会话互不共享", async () => {
  let closed = 0;
  const registry = createTemporaryChats({ createChat: () => ({ close: async () => { closed += 1; } }), idleMs: 20 });
  const first = await registry.create();
  const second = await registry.create();
  assert.notEqual(first, second);
  assert.notEqual(registry.get(first), registry.get(second));
  await registry.close(first);
  assert.throws(() => registry.get(first), { status: 404 });
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.throws(() => registry.get(second), { status: 404 });
  assert.equal(closed, 2);
});

test("异常退出后的清理仅删除过期且进程已退出的临时目录", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "wenxiang-cleanup-test-"));
  const old = path.join(root, "wenxiang-chat-v1-123456-abcdef");
  const alive = path.join(root, "wenxiang-chat-v1-123457-abcdef");
  const unrelated = path.join(root, "other-directory");
  try {
    for (const dir of [old, alive, unrelated]) {
      await mkdir(dir);
      await writeFile(path.join(dir, "file"), "test");
      await utimes(dir, new Date(0), new Date(0));
    }
    await cleanupAbandonedTemporaryChats({ directory: root, now: Date.now(), isAlive: (pid) => pid === 123457 });
    await assert.rejects(stat(old), { code: "ENOENT" });
    assert.equal((await stat(alive)).isDirectory(), true);
    assert.equal((await stat(unrelated)).isDirectory(), true);
  } finally { await rm(root, { recursive: true, force: true }); }
});


test("model selection keeps the thread and close removes generated files", async () => {
  const fake = fakeCodex();
  const chat = new TemporaryChat({ executable: "fake", model: "default-model", spawnImpl: () => fake.child });
  await chat.prompt("first", () => {}, "model-one");
  await mkdir(path.join(chat.cwd, "generated"));
  await writeFile(path.join(chat.cwd, "generated", "result.txt"), "temporary");
  await chat.prompt("second", () => {}, "model-two");
  await chat.prompt("default", () => {});
  const turns = fake.requests.filter((r) => r.method === "turn/start");
  assert.deepEqual(turns.map((r) => r.params.model), ["model-one", "model-two", "default-model"]);
  assert.equal(new Set(turns.map((r) => r.params.threadId)).size, 1);
  const dir = chat.cwd;
  await chat.close();
  await assert.rejects(stat(dir), { code: "ENOENT" });
});
