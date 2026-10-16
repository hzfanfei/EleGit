import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import {
  loadChatImages,
  promptImageRefs,
  readChatImage,
  sanitizeImageRefs,
  saveChatImage,
} from "../src/chat-images.js";

const id = "ab".repeat(16);

describe("chat images", () => {
  it("keeps only safe ids and caps each message", () => {
    const refs = sanitizeImageRefs([
      { id },
      { id: "../etc/passwd" },
      { id },
      { id: "zz" },
      { id: "cd".repeat(16) },
      { id: "ef".repeat(16) },
      { id: "12".repeat(16) },
      { id: "34".repeat(16) },
    ]);
    assert.deepEqual(refs.map((item) => item.id), [
      id,
      "cd".repeat(16),
      "ef".repeat(16),
      "12".repeat(16),
    ]);
  });

  it("sends current images on a warm session and recent history after reconnect", () => {
    const history = [
      { role: "user", content: "先看这个", images: [{ id: "11".repeat(16) }] },
      { role: "assistant", content: "看到了" },
      { role: "user", content: "再看", images: [{ id }] },
    ];
    assert.deepEqual(
      promptImageRefs({ history, images: [{ id }], primed: true }),
      [{ id }],
    );
    assert.deepEqual(
      promptImageRefs({ history, images: [{ id }], primed: false }).map((item) => item.id),
      ["11".repeat(16), id],
    );
  });

  it("round-trips bytes on disk", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "wx-chat-img-"));
    try {
      const saved = await saveChatImage(Buffer.from("pixels"), "image/png", dir);
      const read = await readChatImage(saved.id, dir);
      assert.equal(read.mimeType, "image/png");
      assert.equal(read.bytes.toString(), "pixels");
      const loaded = await loadChatImages([saved, { id: "00".repeat(16) }], dir);
      assert.equal(loaded.length, 1);
      assert.equal(loaded[0].data, Buffer.from("pixels").toString("base64"));
      assert.equal(loaded[0].path, read.path);
      await assert.rejects(() => saveChatImage(Buffer.from("x"), "text/plain", dir));
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
