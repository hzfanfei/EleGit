import assert from "node:assert/strict";
import { createServer } from "node:http";
import { describe, it } from "node:test";
import { WebSocket } from "ws";
import { attachVoiceGateway, isVoiceUpgrade, voiceKeyFromRequest } from "../src/voice-ws.js";

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

describe("voice websocket", () => {
  it("reads the API key from header or query and only matches /v1/voice", () => {
    assert.equal(isVoiceUpgrade({ url: "/v1/voice?key=abc" }), true);
    assert.equal(isVoiceUpgrade({ url: "/v1/chat" }), false);
    assert.equal(voiceKeyFromRequest({ url: "/v1/voice?key=from-query", headers: {} }), "from-query");
    assert.equal(
      voiceKeyFromRequest({ url: "/v1/voice", headers: { "x-wenxiang-key": "from-header" } }),
      "from-header",
    );
  });

  it("rejects a missing key and tells an authenticated client when voice is unconfigured", async () => {
    const server = await listen();
    attachVoiceGateway(server, {
      getApiKey: () => "test-key",
      resolveConfig: () => ({ ready: false, hint: "还没配语音密钥" }),
      createAsk: () => async function* () {},
      createProviders: () => ({ asr: null, tts: null }),
    });
    const { port } = server.address();
    try {
      const denied = await new Promise((resolve) => {
        const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/voice`);
        ws.on("unexpected-response", (_req, res) => resolve(res.statusCode));
        ws.on("open", () => resolve("opened"));
        ws.on("error", () => {});
      });
      assert.equal(denied, 401);

      const ws = new WebSocket(`ws://127.0.0.1:${port}/v1/voice?key=test-key`);
      const firstP = waitMessage(ws);
      await new Promise((resolve, reject) => {
        ws.once("open", resolve);
        ws.once("error", reject);
      });
      ws.send(JSON.stringify({ type: "hello", owner: "octo", repo: "demo" }));
      const first = JSON.parse(String(await firstP));
      assert.equal(first.type, "error");
      assert.equal(first.code, "unconfigured");
      assert.equal(first.hint, "还没配语音密钥");
      ws.close();
    } finally {
      server.close();
    }
  });
});
