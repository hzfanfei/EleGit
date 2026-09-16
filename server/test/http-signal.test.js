import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { describe, it } from "node:test";
import { isCancelled, requestSignal } from "../src/http-signal.js";

function mockReqRes() {
  const req = new EventEmitter();
  req.aborted = false;
  const res = new EventEmitter();
  res.writableEnded = false;
  return { req, res };
}

describe("requestSignal", () => {
  it("does not abort when the request body stream closes after Express parsed JSON", () => {
    const { req, res } = mockReqRes();
    const signal = requestSignal(req, res);
    req.emit("close");
    assert.equal(signal.aborted, false);
  });

  it("aborts only when the client drops the response before it ends", () => {
    const { req, res } = mockReqRes();
    const signal = requestSignal(req, res);
    res.emit("close");
    assert.equal(signal.aborted, true);
  });

  it("does not abort after a finished response closes", () => {
    const { req, res } = mockReqRes();
    const signal = requestSignal(req, res);
    res.writableEnded = true;
    res.emit("close");
    assert.equal(signal.aborted, false);
  });

  it("aborts when the request is actually aborted", () => {
    const { req, res } = mockReqRes();
    const signal = requestSignal(req, res);
    req.emit("aborted");
    assert.equal(signal.aborted, true);
  });
});

describe("isCancelled", () => {
  it("recognizes abort errors", () => {
    const err = new Error("cancelled");
    err.code = "cancelled";
    assert.equal(isCancelled(err), true);
    assert.equal(isCancelled(new Error("fatal: not a git repository")), false);
  });
});
