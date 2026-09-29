import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { answerReadyNotice } from "../src/ask.js";
import {
  clearLiveTurn,
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

describe("relay recycle", () => {
  it("replaces an idle relay running older code and keeps a busy one", () => {
    assert.equal(relayNeedsRecycle({
      alive: true,
      runningStamp: "",
      sourceStamp: "2",
      busy: false,
    }), true);
    assert.equal(relayNeedsRecycle({
      alive: true,
      runningStamp: "",
      sourceStamp: "2",
      busy: true,
    }), false);
    assert.equal(relayNeedsRecycle({
      alive: true,
      runningStamp: "2",
      sourceStamp: "2",
      busy: false,
    }), false);
  });
});
