import assert from "node:assert/strict";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { spawnSync } from "node:child_process";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import {
  checkoutPath,
  ensureCheckout,
  formatLocalContext,
  safeSegment,
  snapshotCheckout,
} from "../src/workspace.js";

function git(args, cwd) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "git failed");
  }
}

describe("checkout paths", () => {
  it("joins under the 问象 workspace and rejects traversal", () => {
    const dest = checkoutPath("/tmp/问象", "acme", "widget");
    assert.equal(dest, path.join("/tmp/问象", "acme", "widget"));
    assert.throws(() => safeSegment("../etc", "owner"), /Invalid/);
    assert.throws(() => safeSegment("acme/widget", "repo"), /Invalid/);
  });
});

describe("ensureCheckout", () => {
  it("clones a local git repo and snapshots files", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "wenxiang-src-"));
    const workspace = await mkdtemp(path.join(os.tmpdir(), "wenxiang-ws-"));
    git(["init", "-b", "main"], tmp);
    git(["config", "user.email", "test@example.com"], tmp);
    git(["config", "user.name", "Test"], tmp);
    await writeFile(path.join(tmp, "README.md"), "# widget\nstart with npm start\n");
    await mkdir(path.join(tmp, "src"), { recursive: true });
    await writeFile(path.join(tmp, "src", "app.js"), "export default 1;\n");
    git(["add", "."], tmp);
    git(["commit", "-m", "Initial widget"], tmp);

    const result = await ensureCheckout({
      workspaceRoot: workspace,
      owner: "acme",
      repo: "widget",
      cloneUrl: tmp,
      defaultBranch: "main",
    });
    assert.equal(result.existed, false);
    assert.equal(result.local.present, true);
    assert.match(result.local.path, /acme\/widget$/);
    assert.match(result.local.log, /Initial widget/);
    assert.ok(result.local.files.includes("README.md"));
    assert.match(result.local.readme, /npm start/);

    const again = await ensureCheckout({
      workspaceRoot: workspace,
      owner: "acme",
      repo: "widget",
      cloneUrl: tmp,
      defaultBranch: "main",
    });
    assert.equal(again.existed, true);
    const snap = await snapshotCheckout(result.dest);
    assert.match(formatLocalContext(snap), /Local checkout/);
    assert.match(formatLocalContext(snap), /Initial widget/);
  });
});
