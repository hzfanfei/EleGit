import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { answerReadyNotice } from "../src/ask.js";
import {
  clearLiveTurn,
  createUnwatchedInboxMirror,
  listLiveTurns,
  noteLiveTurn,
  publishLiveTurnSnapshots,
} from "../src/live-turns.js";
import { relayNeedsRecycle } from "../src/turn-relay-client.js";

describe("live turn handoff", () => {
  it("publishes the in-flight answer as a partial inbox row", async () => {
    clearLiveTurn("s1");
    noteLiveTurn({
      session: { id: "s1", owner: "octo", repo: "demo" },
      question: "清空日志",
      answer: "根因已经找到",
      activity: "改·server.js",
    });
    const published = [];
    const count = await publishLiveTurnSnapshots("C:/问象", {
      noticeFor: answerReadyNotice,
      publish: async (_root, notice) => {
        published.push(notice);
      },
    });
    assert.equal(count, 1);
    assert.equal(published[0].partial, true);
    assert.equal(published[0].answer, "根因已经找到");
    assert.equal(published[0].activity, "改·server.js");
    assert.equal(listLiveTurns().length, 1);
    clearLiveTurn("s1");
  });
});

describe("unwatched inbox mirror", () => {
  it("publishes partial progress only while unwatched", async () => {
    clearLiveTurn("s2");
    noteLiveTurn({
      session: { id: "s2", owner: "octo", repo: "demo" },
      question: "查进度",
      activity: "读·README.md",
    });
    let unwatched = false;
    const published = [];
    const mirror = createUnwatchedInboxMirror({
      workspaceRoot: "C:/问象",
      isUnwatched: () => unwatched,
      noticeFor: answerReadyNotice,
      publish: async (_root, notice) => {
        published.push(notice);
      },
      intervalMs: 0,
    });
    mirror.schedule("s2");
    await new Promise((r) => setTimeout(r, 5));
    assert.equal(published.length, 0);

    unwatched = true;
    mirror.schedule("s2");
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(published.length, 1);
    assert.equal(published[0].partial, true);
    assert.equal(published[0].activity, "读·README.md");

    noteLiveTurn({
      session: { id: "s2", owner: "octo", repo: "demo" },
      question: "查进度",
      answer: "正在整理",
      activity: "读·README.md",
    });
    mirror.schedule("s2");
    await new Promise((r) => setTimeout(r, 10));
    assert.equal(published.length, 2);
    assert.equal(published[1].answer, "正在整理");
    mirror.dispose();
    clearLiveTurn("s2");
  });
});

describe("relay recycle", () => {
  it("replaces a stale relay even when agents are still attached", () => {
    assert.equal(relayNeedsRecycle({
      alive: true,
      runningStamp: "",
      sourceStamp: "2",
    }), true);
    assert.equal(relayNeedsRecycle({
      alive: true,
      runningStamp: "1",
      sourceStamp: "2",
    }), true);
    assert.equal(relayNeedsRecycle({
      alive: false,
      runningStamp: "1",
      sourceStamp: "2",
    }), false);
    assert.equal(relayNeedsRecycle({
      alive: true,
      runningStamp: "2",
      sourceStamp: "2",
    }), false);
  });
});
