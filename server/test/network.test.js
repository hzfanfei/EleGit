import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { lanUrls } from "../src/network.js";

describe("lanUrls", () => {
  it("returns http URLs with the given port", () => {
    const urls = lanUrls(8787);
    for (const url of urls) {
      assert.match(url, /^http:\/\/\d+\.\d+\.\d+\.\d+:8787$/);
    }
  });
});
