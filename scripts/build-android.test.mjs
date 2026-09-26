import assert from "node:assert/strict";
import test from "node:test";

import { nextBuildNumber, parseVersion, replaceVersionLine } from "./build-android.mjs";

test("build number increments and is written back", () => {
  const text = "name: wenxiang\nversion: 0.1.0+1\n";
  const { name, build } = parseVersion(text);
  assert.equal(name, "0.1.0");
  assert.equal(build, "1");
  const next = nextBuildNumber(build);
  assert.equal(next, "2");
  assert.equal(replaceVersionLine(text, name, next), "name: wenxiang\nversion: 0.1.0+2\n");
});

test("a missing build starts at 1", () => {
  assert.equal(nextBuildNumber(""), "1");
  assert.equal(parseVersion("version: 0.1.0\n").build, "");
});
