import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DIAGRAM_ONLY_SPOKEN,
  buildSpeakSummaryPrompt,
  clipAnswerForSpeech,
  runSpeakSummary,
  speakSummaryCommand,
} from "../src/speak-summary.js";

describe("speak summary", () => {
  it("uses Claude Code and its current model, not the repo chat engine", () => {
    const prev = process.env.WENXIANG_ACP_ENGINE;
    const prevModel = process.env.WENXIANG_ACP_MODEL;
    process.env.WENXIANG_ACP_ENGINE = "cursor";
    process.env.WENXIANG_ACP_MODEL = "grok-4.7-high-fast";
    try {
      const command = speakSummaryCommand();
      if (!command) return;
      assert.equal(command.provider, "claude");
      assert.notEqual(command.model, "grok-4.7-high-fast");
    } finally {
      if (prev !== undefined) process.env.WENXIANG_ACP_ENGINE = prev;
      else delete process.env.WENXIANG_ACP_ENGINE;
      if (prevModel !== undefined) process.env.WENXIANG_ACP_MODEL = prevModel;
      else delete process.env.WENXIANG_ACP_MODEL;
    }
  });

  it("clips markup down to prose and asks for spoken Chinese", () => {
    const clipped = clipAnswerForSpeech("## 进度\n\n登录已经修好。\n\n```js\nconst x = 1\n```");
    assert.match(clipped, /登录已经修好/);
    assert.equal(clipped.includes("```"), false);
    const prompt = buildSpeakSummaryPrompt(clipped);
    assert.match(prompt, /不要调用工具/);
    assert.match(prompt, /登录已经修好/);
  });

  it("rewrites the answer and sends that text to TTS", async () => {
    const spoken = [];
    const result = await runSpeakSummary({
      text: "仓库最近在修登录，另外还改了打包脚本。",
      prompt: async (_prompt, { onDelta }) => {
        onDelta("登录已经修好。打包脚本也改过了。");
      },
      tts: async (text) => {
        spoken.push(text);
        return Buffer.from([1, 2, 3, 4]);
      },
      onAudio: async () => {},
    });
    assert.match(result, /登录已经修好/);
    assert.deepEqual(spoken, ["登录已经修好。打包脚本也改过了。"]);
  });

  it("speaks a short line when the answer is only a diagram", async () => {
    let prompted = false;
    const spoken = [];
    const result = await runSpeakSummary({
      text: "```mermaid\nflowchart TD\n  A-->B\n```",
      prompt: async () => {
        prompted = true;
      },
      tts: async (text) => {
        spoken.push(text);
        return Buffer.from([1, 2]);
      },
      onAudio: async () => {},
    });
    assert.equal(prompted, false);
    assert.equal(result, DIAGRAM_ONLY_SPOKEN);
    assert.deepEqual(spoken, [DIAGRAM_ONLY_SPOKEN]);
  });
});
