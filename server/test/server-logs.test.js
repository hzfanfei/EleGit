import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { appendClientLogs, clientLogFile } from "../src/client-logs.js";
import {
  configureServerLogs,
  listErrorLogs,
  noteServerLog,
  serverLogFile,
} from "../src/server-logs.js";

describe("server logs", () => {
  it("records voice errors and lists them with uploaded client logs", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-server-logs-"));
    try {
      configureServerLogs(root);
      noteServerLog({
        kind: "voice-asr",
        message: "Volc ASR websocket closed",
        summary: "语音识别中断",
      });
      await appendClientLogs(
        root,
        [{ id: "c1", at: "2026-09-25T01:00:00.000Z", kind: "shown", message: "Connection refused" }],
        { app: "wenxiang", platform: "android" },
      );
      await new Promise((resolve) => setTimeout(resolve, 30));
      const rows = await listErrorLogs(root, { limit: 10 });
      assert.equal(rows.length, 2);
      assert.equal(rows[0].origin, "server");
      assert.equal(rows[1].origin, "client");
      assert.match(rows[0].message, /ASR/);
      const serverText = await readFile(serverLogFile(root), "utf8");
      assert.match(serverText, /voice-asr/);
      const clientText = await readFile(clientLogFile(root), "utf8");
      assert.match(clientText, /Connection refused/);
    } finally {
      configureServerLogs("");
      await rm(root, { recursive: true, force: true });
    }
  });
});
