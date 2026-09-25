import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { appendClientLogs, clientLogFile, sanitizeClientEntry } from "../src/client-logs.js";

describe("client logs", () => {
  it("keeps the error reason and discards empty messages", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-client-logs-"));
    try {
      const accepted = await appendClientLogs(
        root,
        [
          {
            id: "a",
            at: "2026-09-25T00:00:00.000Z",
            kind: "shown",
            message: "SocketException: Connection refused",
            summary: "连不上本机问象服务。请确认电脑上的服务已启动。",
            stack: "main.dart:1",
          },
          { id: "b", message: "   " },
          { id: "c", message: "cancelled" },
        ],
        { app: "wenxiang", platform: "android" },
      );
      assert.deepEqual(accepted, ["a", "b", "c"]);
      const text = await readFile(clientLogFile(root), "utf8");
      const lines = text.trim().split("\n");
      assert.equal(lines.length, 1);
      const stored = JSON.parse(lines[0]);
      assert.equal(stored.id, "a");
      assert.equal(stored.message, "SocketException: Connection refused");
      assert.match(stored.summary, /连不上本机问象服务/);
      assert.equal(stored.platform, "android");
      assert.equal(stored.app, "wenxiang");
      assert.equal(stored.stack, "main.dart:1");
      assert.ok(stored.receivedAt);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("redacts secrets and clips oversized fields", () => {
    const clean = sanitizeClientEntry({
      id: "a",
      message: `header X-Wenxiang-Key: abcdef123456 ${"m".repeat(2100)}`,
      stack: `Bearer ghp_supersecret ${"s".repeat(5000)}`,
    });
    assert.equal(clean.message.includes("abcdef123456"), false);
    assert.match(clean.message, /X-Wenxiang-Key: \[redacted\]/);
    assert.ok(clean.message.length <= 2000);
    assert.equal(clean.stack.includes("ghp_supersecret"), false);
    assert.ok(clean.stack.length <= 4000);
  });

  it("drops older lines once the log file outgrows its cap", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-client-logs-"));
    try {
      await appendClientLogs(root, [{ id: "1", message: "first failure" }]);
      await appendClientLogs(root, [{ id: "2", message: "second failure" }], {
        maxBytes: 10,
        keepBytes: 10,
      });
      const text = await readFile(clientLogFile(root), "utf8");
      assert.match(text, /second failure/);
      assert.doesNotMatch(text, /first failure/);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });
});
