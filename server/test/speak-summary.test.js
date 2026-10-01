import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  DIAGRAM_ONLY_SPOKEN,
  buildSpeakSummaryPrompt,
  clipAnswerForSpeech,
  completeSpeakSummary,
  runSpeakSummary,
  speakSummaryApiConfig,
  speakSummaryMessagesUrl,
  textFromMessagesResponse,
} from "../src/speak-summary.js";

describe("speak summary", () => {
  it("calls Claude Code's current model API, not the repo chat engine", () => {
    const config = speakSummaryApiConfig({
      model: "ignored-by-env-field",
      env: {
        ANTHROPIC_MODEL: "MiniMax-M3",
        ANTHROPIC_BASE_URL: "https://api.minimaxi.com/anthropic/",
        ANTHROPIC_AUTH_TOKEN: "sk-test",
      },
    });
    assert.equal(config.model, "MiniMax-M3");
    assert.equal(config.base, "https://api.minimaxi.com/anthropic");
    assert.equal(config.auth, "bearer");
    assert.equal(config.token, "sk-test");
    assert.equal(
      speakSummaryMessagesUrl(config.base),
      "https://api.minimaxi.com/anthropic/v1/messages",
    );
    assert.equal(speakSummaryApiConfig({ env: { ANTHROPIC_MODEL: "MiniMax-M3" } }), null);
  });

  it("posts one messages request and skips thinking blocks", async () => {
    let seen;
    const text = await completeSpeakSummary("改写成口语", {
      config: {
        model: "MiniMax-M3",
        base: "https://api.minimaxi.com/anthropic",
        token: "sk-test",
        auth: "bearer",
      },
      fetchImpl: async (url, init) => {
        seen = { url, init };
        return {
          ok: true,
          status: 200,
          text: async () =>
            JSON.stringify({
              content: [
                { type: "thinking", thinking: "先想一下" },
                { type: "text", text: "登录已经修好。" },
              ],
            }),
        };
      },
    });
    assert.equal(text, "登录已经修好。");
    assert.equal(seen.url, "https://api.minimaxi.com/anthropic/v1/messages");
    const body = JSON.parse(seen.init.body);
    assert.equal(body.model, "MiniMax-M3");
    assert.equal(body.tools, undefined);
    assert.equal(body.messages.length, 1);
    assert.equal(seen.init.headers.authorization, "Bearer sk-test");
    assert.equal(textFromMessagesResponse({ content: [{ type: "thinking", thinking: "x" }] }), "");
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
