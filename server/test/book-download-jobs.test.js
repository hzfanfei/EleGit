import assert from "node:assert/strict";
import { describe, it } from "node:test";
import {
  getBookDownloadJob,
  startBookDownloadJob,
} from "../src/book-download-jobs.js";

describe("book-download-jobs", () => {
  it("returns pending then done for a fast mock download", async () => {
    const orig = globalThis.fetch;
    globalThis.fetch = async () => ({
      ok: true,
      headers: { get: () => "application/epub+zip" },
      body: (async function* () {
        yield Buffer.from("PK\x03\x04\x00\x00");
        yield Buffer.alloc(0);
      })(),
    });

    try {
      const jobId = startBookDownloadJob({
        url: "https://archive.org/download/demo/book.epub",
        title: "Demo",
        workspaceRoot: process.cwd(),
      });
      assert.ok(jobId);
      let job = getBookDownloadJob(jobId);
      assert.equal(job.status, "pending");

      const deadline = Date.now() + 5000;
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 50));
        job = getBookDownloadJob(jobId);
        if (job.status !== "pending") break;
      }
      assert.equal(job.status, "done");
      assert.ok(job.result?.filename?.endsWith(".epub"));
    } finally {
      globalThis.fetch = orig;
    }
  });
});
