import assert from "node:assert/strict";
import { createServer } from "node:http";
import { describe, it } from "node:test";
import { WebSocket } from "ws";
import {
  adoptSttFinal,
  attachSttGateway,
  commitSttPartial,
  composeSttDisplay,
  createSttSession,
  isSttUpgrade,
  mergeSttPartial,
} from "../src/voice-stt-ws.js";

function listen() {
  return new Promise((resolve) => {
    const server = createServer();
    server.listen(0, "127.0.0.1", () => resolve(server));
  });
}

function waitMessage(ws) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("ws timeout")), 3000);
    ws.once("message", (data) => {
      clearTimeout(timer);
      resolve(data);
    });
    ws.once("error", reject);
  });
}

describe("voice stt websocket", () => {
  it("only matches /v1/voice/stt", () => {
    assert.equal(isSttUpgrade({ url: "/v1/voice/stt?key=abc" }), true);
    assert.equal(isSttUpgrade({ url: "/v1/voice" }), false);
  });

  it("rejects missing key and reports unconfigured when voice keys are absent", async () => {
    const server = await listen();
    attachSttGateway(server, {
      getApiKey: () => "test-key",
      resolveConfig: () => ({ ready: false, hint: "还没配语音密钥" }),
      createProviders: () => ({ asr: null, tts: null }),
    });
    const { port } = server.address();
    try {
      const denied = await new Promise((resolve) => {
        const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/voice/stt`);
        ws.on("unexpected-response", (_req, res) => resolve(res.statusCode));
        ws.on("open", () => resolve("opened"));
        ws.on("error", () => {});
      });
      assert.equal(denied, 401);

      const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/voice/stt?key=test-key`);
      const firstP = waitMessage(ws);
      await new Promise((resolve, reject) => {
        ws.once("open", resolve);
        ws.once("error", reject);
      });
      const first = JSON.parse(String(await firstP));
      assert.equal(first.type, "error");
      assert.equal(first.code, "unconfigured");
      ws.close();
    } finally {
      server.close();
    }
  });

  it("composes multi-segment hold-to-talk captions without dropping earlier words", () => {
    const segments = [];
    adoptSttFinal(segments, "第一句话。");
    let partial = mergeSttPartial({
      segments,
      partial: "",
      incoming: "第二句",
      partialMode: "cumulative",
    });
    assert.equal(composeSttDisplay(segments, partial), "第一句话。第二句");
    adoptSttFinal(segments, "第二句还在说");
    partial = "";
    assert.equal(composeSttDisplay(segments, partial), "第一句话。第二句还在说");
  });

  it("done text keeps earlier utterance when only the last gets a provider final", async () => {
    const out = [];
    const wired = createSttSession({
      config: { ready: true, provider: "volc", volc: {} },
      send: (msg) => out.push(msg),
      createProviders: (_config, hooks) => ({
        asr: {
          async start() {},
          push() {},
          async finalize() {
            hooks.onPartial?.("第一句话。");
            hooks.onFinal?.("第二句话。");
          },
          stop() {},
        },
        tts: null,
      }),
    });
    await wired.start();
    wired.onPcm(Buffer.from([0, 0]));
    await wired.stop();
    const done = out.find((msg) => msg.type === "done");
    assert.match(done?.text || "", /第一句话/);
    assert.match(done?.text || "", /第二句话/);
  });

  it("commitSttPartial preserves partial before a new final chunk", () => {
    const segments = [];
    commitSttPartial(segments, "第一句话。");
    adoptSttFinal(segments, "第二句话。");
    assert.equal(composeSttDisplay(segments, ""), "第一句话。第二句话。");
  });

  it("returns done text from a fake ASR on stop", async () => {
    const out = [];
    const wired = createSttSession({
      config: { ready: true, provider: "volc", volc: {} },
      send: (msg) => out.push(msg),
      createProviders: (_config, hooks) => ({
        asr: {
          async start() {},
          push() {
            hooks.onPartial?.("你好");
          },
          async finalize() {
            hooks.onFinal?.("你好世界");
          },
          stop() {},
        },
        tts: null,
      }),
    });
    await wired.start();
    wired.onPcm(Buffer.from([0, 0]));
    await wired.stop();
    const done = out.find((msg) => msg.type === "done");
    assert.equal(done?.text, "你好世界");
  });
});
