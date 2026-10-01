import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { commandAlive, keepEndedScriptRows, planScriptActivityUpdates } from "../src/script-activity.js";

const stuck = {
  id: "inb1",
  partial: true,
  activity: "跑脚本\nnode scripts/restart-companion.mjs · 已跑 1 秒",
};

describe("planScriptActivityUpdates", () => {
  it("counts up while the command is still running", () => {
    const anchors = new Map();
    const now = 10_000;
    const first = planScriptActivityUpdates([stuck], {
      commands: ["node scripts/restart-companion.mjs"],
      now,
      anchors,
    });
    assert.equal(first.length, 0);
    const next = planScriptActivityUpdates([stuck], {
      commands: ["node scripts/restart-companion.mjs"],
      now: now + 2000,
      anchors,
    });
    assert.equal(next.length, 1);
    assert.match(next[0].activity, /已跑 3 秒/);
  });

  it("ends the row after the command is gone twice", () => {
    const anchors = new Map();
    const once = planScriptActivityUpdates([stuck], {
      commands: [],
      now: 10_000,
      anchors,
    });
    assert.equal(once.length, 0);
    const twice = planScriptActivityUpdates([stuck], {
      commands: [],
      now: 12_000,
      anchors,
    });
    assert.equal(twice.length, 1);
    assert.match(twice[0].activity, /已结束/);
    assert.doesNotMatch(twice[0].activity, /已跑/);
  });

  it("counts a Windows command line that only shares the script path", () => {
    const anchors = new Map();
    const now = 10_000;
    const win = String.raw`"C:\Program Files\nodejs\node.exe" C:\Users\Administrator\wenxiang\hzfanfei\EleGit\scripts\restart-companion.mjs`;
    planScriptActivityUpdates([stuck], { commands: [win], now, anchors });
    const next = planScriptActivityUpdates([stuck], {
      commands: [win],
      now: now + 2000,
      anchors,
    });
    assert.equal(next.length, 1);
    assert.match(next[0].activity, /已跑 3 秒/);
  });

  it("treats npm test as alive only when both words are on the same line", () => {
    assert.equal(commandAlive("npm test", ["npm test"]), true);
    assert.equal(commandAlive("npm test", ["node scripts/test-runner.js"]), false);
    assert.equal(
      commandAlive("node scripts/restart-companion.mjs", [
        String.raw`C:\Program Files\nodejs\node.exe C:\repo\scripts\restart-companion.mjs`,
      ]),
      true,
    );
  });

  it("keeps 已结束 when a later pulse writes 已跑 again", () => {
    const prev = "跑脚本\nnode scripts/restart-companion.mjs · 已结束";
    const next = "跑脚本\nnode scripts/restart-companion.mjs · 已跑 4 秒";
    const kept = keepEndedScriptRows(prev, next);
    assert.match(kept, /已结束/);
    assert.doesNotMatch(kept, /已跑/);
    const finished = keepEndedScriptRows(
      prev,
      "跑脚本\nnode scripts/restart-companion.mjs · stopped companion",
    );
    assert.match(finished, /stopped companion/);
  });

  it("leaves a row alone once the wait label is gone", () => {
    const done = {
      id: "inb2",
      partial: true,
      activity: "跑脚本\nnode scripts/restart-companion.mjs · stopped companion",
    };
    const patches = planScriptActivityUpdates([done], {
      commands: [],
      now: 10_000,
      anchors: new Map(),
    });
    assert.equal(patches.length, 0);
  });
});
