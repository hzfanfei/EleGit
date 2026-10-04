import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { appendInboxItem, listInbox, markInboxRead, patchInboxActivity } from "../src/inbox.js";

describe("inbox turn progress", () => {
  it("replaces the open partial with the finished answer", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-inbox-"));
    try {
      const partial = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答编写中",
        body: "先写",
        answer: "先写",
        sessionId: "s1",
        question: "进度如何",
        partial: true,
      });
      const done = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答已就绪",
        body: "先写完了",
        answer: "先写完了",
        sessionId: "s1",
        question: "进度如何",
      });
      const items = await listInbox(root);
      assert.equal(items.length, 1);
      assert.equal(items[0].id, partial.id);
      assert.equal(items[0].id, done.id);
      assert.equal(items[0].answer, "先写完了");
      assert.equal(items[0].partial, false);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("patches activity only while the partial text is unchanged", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-inbox-"));
    try {
      const partial = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答编写中",
        body: "跑脚本",
        answer: "",
        sessionId: "s1",
        question: "重启下服务",
        partial: true,
        activity: "跑脚本\nnode scripts/restart-companion.mjs · 已跑 1 秒",
      });
      const patched = await patchInboxActivity(
        root,
        partial.id,
        partial.activity,
        "跑脚本\nnode scripts/restart-companion.mjs · 已跑 2 秒",
      );
      assert.equal(patched.activity.includes("已跑 2 秒"), true);
      const skipped = await patchInboxActivity(
        root,
        partial.id,
        partial.activity,
        "跑脚本\nnode scripts/restart-companion.mjs · 已跑 9 秒",
      );
      assert.equal(skipped, null);
      const items = await listInbox(root);
      assert.equal(items[0].activity.includes("已跑 2 秒"), true);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("does not let a later partial revive a script that already ended", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-inbox-"));
    try {
      await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答编写中",
        body: "跑脚本",
        answer: "",
        sessionId: "s1",
        question: "重启下服务",
        partial: true,
        activity: "跑脚本\nnode scripts/restart-companion.mjs · 已结束",
      });
      const revived = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答编写中",
        body: "跑脚本",
        answer: "",
        sessionId: "s1",
        question: "重启下服务",
        partial: true,
        activity: "跑脚本\nnode scripts/restart-companion.mjs · 已跑 3 秒",
      });
      assert.match(revived.activity, /已结束/);
      assert.doesNotMatch(revived.activity, /已跑/);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("keeps progress unread-free and alerts a turn only once", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-inbox-"));
    try {
      const partial = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答编写中",
        body: "先写",
        answer: "先写",
        sessionId: "s1",
        question: "进度如何",
        turnId: "turn-a",
        partial: true,
      });
      assert.equal(partial.partial, true);
      assert.equal(partial.read, true);
      assert.equal(partial.alert, false);
      const done = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答已就绪",
        body: "写完了",
        answer: "写完了",
        sessionId: "s1",
        question: "进度如何",
        turnId: "turn-a",
      });
      assert.equal(done.id, partial.id);
      assert.equal(done.partial, false);
      assert.equal(done.read, false);
      assert.equal(done.alert, true);
      await markInboxRead(root, done.id);
      const again = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答已就绪",
        body: "又写了一遍",
        answer: "又写了一遍",
        sessionId: "s1",
        question: "进度如何",
        turnId: "turn-a",
      });
      assert.equal(again.alert, false);
      assert.equal(again.read, true);
      const late = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答编写中",
        body: "还在写",
        answer: "还在写",
        sessionId: "s1",
        question: "进度如何",
        turnId: "turn-a",
        partial: true,
      });
      assert.equal(late.answer, "又写了一遍");
      assert.equal(late.partial, false);
      const items = await listInbox(root);
      assert.equal(items.length, 1);
      assert.equal(items[0].read, true);
      const other = await appendInboxItem(root, {
        kind: "agent-notification",
        title: "回答已就绪",
        body: "另一问",
        answer: "另一问",
        sessionId: "s1",
        question: "进度如何",
        turnId: "turn-b",
      });
      assert.equal(other.alert, true);
      assert.equal((await listInbox(root)).length, 2);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
