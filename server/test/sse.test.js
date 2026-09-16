import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { flushSse, openSse, writeSse } from "../src/sse.js";

function mockRes() {
  const headers = {};
  const writes = [];
  let flushCount = 0;
  let flushedHeaders = false;
  let noDelay = false;
  return {
    statusCode: 0,
    headers,
    writes,
    get flushCount() {
      return flushCount;
    },
    get flushedHeaders() {
      return flushedHeaders;
    },
    get noDelay() {
      return noDelay;
    },
    status(code) {
      this.statusCode = code;
      return this;
    },
    setHeader(key, value) {
      headers[key] = value;
    },
    flushHeaders() {
      flushedHeaders = true;
    },
    flush() {
      flushCount += 1;
    },
    write(chunk) {
      writes.push(String(chunk));
      return true;
    },
    socket: {
      setNoDelay() {
        noDelay = true;
      },
    },
  };
}

describe("SSE writer", () => {
  it("opens the stream with anti-buffering headers and flushes a pad", () => {
    const res = mockRes();
    openSse(res);
    assert.equal(res.statusCode, 200);
    assert.equal(res.headers["Content-Type"], "text/event-stream; charset=utf-8");
    assert.equal(res.headers["Cache-Control"], "no-cache, no-transform");
    assert.equal(res.headers["X-Accel-Buffering"], "no");
    assert.equal(res.headers["Content-Encoding"], "identity");
    assert.equal(res.flushedHeaders, true);
    assert.equal(res.noDelay, true);
    assert.match(res.writes[0], /^:[ ]{2048}\n\n$/);
    assert.ok(res.flushCount >= 1);
  });

  it("writes one SSE event and flushes so a phone can see it immediately", () => {
    const res = mockRes();
    writeSse(res, { type: "delta", text: "最" });
    assert.equal(res.writes.join(""), 'data: {"type":"delta","text":"最"}\n\n');
    assert.equal(res.flushCount, 1);
    writeSse(res, { type: "delta", text: "近" });
    assert.equal(res.flushCount, 2);
  });

  it("flushSse is a no-op when the response has no flush hook", () => {
    const res = { write() {} };
    flushSse(res);
  });
});
