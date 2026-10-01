import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { listeningPidsFromNetstat } from "../src/listen-pid.js";

const sample = `
  TCP    0.0.0.0:8787           0.0.0.0:0              LISTENING       4242
  TCP    127.0.0.1:18787        0.0.0.0:0              LISTENING       99
  TCP    [::]:8787              [::]:0                 LISTENING       4242
  TCP    127.0.0.1:8787         127.0.0.1:50000        ESTABLISHED     4242
  TCP    0.0.0.0:80             0.0.0.0:0              LISTENING       4
`;

describe("listeningPidsFromNetstat", () => {
  it("returns unique listeners for the port and skips a longer port", () => {
    assert.deepEqual(listeningPidsFromNetstat(sample, 8787), [4242]);
    assert.deepEqual(listeningPidsFromNetstat(sample, 18787), [99]);
    assert.deepEqual(listeningPidsFromNetstat(sample, 443), []);
  });
});
