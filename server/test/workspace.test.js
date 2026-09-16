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
  gitAuthConfigArgs,
  gitFailure,
  GITHUB_GIT_FORBIDDEN_ZH,
  runGit,
  safeSegment,
  snapshotCheckout,
} from "../src/workspace.js";

function git(args, cwd) {
  const result = spawnSync("git", args, { cwd, encoding: "utf8" });
  if (result.status !== 0) {
    throw new Error(result.stderr || result.stdout || "git failed");
  }
}

const FAKE_OAUTH_TOKEN = "gho_test_placeholder_token";

describe("git auth header", () => {
  it("sends Basic x-access-token via http.extraHeader, not Bearer", () => {
    const args = gitAuthConfigArgs(FAKE_OAUTH_TOKEN);
    assert.equal(args[0], "-c");
    assert.match(args[1], /^http\.extraHeader=Authorization: Basic [A-Za-z0-9+/=]+$/);
    assert.doesNotMatch(args.join(" "), /Bearer/);
    const encoded = args[1].slice("http.extraHeader=Authorization: Basic ".length);
    assert.equal(Buffer.from(encoded, "base64").toString("utf8"), `x-access-token:${FAKE_OAUTH_TOKEN}`);
    assert.ok(!args[1].includes(FAKE_OAUTH_TOKEN), "token must not appear in plaintext in git argv");
  });

  it("omits extraHeader when there is no token", () => {
    assert.deepEqual(gitAuthConfigArgs(""), []);
    assert.deepEqual(gitAuthConfigArgs(undefined), []);
  });

  it("keeps the public HTTPS remote and does not embed the token in the URL", () => {
    const remote = "https://github.com/acme/widget.git";
    const argv = [...gitAuthConfigArgs(FAKE_OAUTH_TOKEN), "clone", remote, "/tmp/widget"];
    assert.ok(argv.includes(remote));
    assert.ok(!argv.some((part) => /x-access-token:/i.test(part)));
    assert.ok(!argv.some((part) => /^https:\/\/.*@github\.com/.test(part)));
  });

  it("rejects immediately when the abort signal is already set", async () => {
    const ac = new AbortController();
    ac.abort();
    await assert.rejects(() => runGit(["status"], { signal: ac.signal }), /cancelled/);
  });

  it("maps GitHub 403 clone failures to a Chinese permission hint", () => {
    const err = gitFailure(
      "remote: Write access to repository not granted.\nfatal: unable to access 'https://github.com/acme/secret.git/': The requested URL returned error: 403",
    );
    assert.equal(err.status, 403);
    assert.equal(err.message, GITHUB_GIT_FORBIDDEN_ZH);
    assert.match(err.message, /私有|repo|SSO/);
    assert.ok(!err.message.includes(FAKE_OAUTH_TOKEN));
  });

  it("maps Authentication failed / SSO denials the same way", () => {
    const auth = gitFailure("fatal: Authentication failed for 'https://github.com/acme/secret.git/'");
    assert.equal(auth.status, 403);
    assert.equal(auth.message, GITHUB_GIT_FORBIDDEN_ZH);
    const sso = gitFailure("remote: Resource protected by organization SAML SSO enforcement.");
    assert.equal(sso.status, 403);
    assert.equal(sso.message, GITHUB_GIT_FORBIDDEN_ZH);
  });

  it("leaves unrelated git errors as short Chinese, not English fatals", () => {
    const err = gitFailure("fatal: not a git repository");
    assert.match(err.message, /[\u4e00-\u9fff]/);
    assert.ok(!/^fatal:/i.test(err.message));
    assert.notEqual(err.status, 403);
  });

  it("maps leftover dest and missing repos to short Chinese", () => {
    const exists = gitFailure(
      "fatal: destination path '/home/fei/问象/octo/demo' already exists and is not an empty directory",
    );
    assert.match(exists.message, /目录|不完整|重试/);
    assert.ok(!exists.message.includes("already exists"));
    const missing = gitFailure("remote: Repository not found.\nfatal: repository 'https://github.com/acme/nope.git/' not found");
    assert.match(missing.message, /找不到|仓库/);
  });
});

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
      token: FAKE_OAUTH_TOKEN,
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
      token: FAKE_OAUTH_TOKEN,
      defaultBranch: "main",
    });
    assert.equal(again.existed, true);
    const origin = spawnSync("git", ["remote", "get-url", "origin"], {
      cwd: result.dest,
      encoding: "utf8",
    });
    assert.equal(origin.status, 0);
    assert.equal(origin.stdout.trim(), tmp);
    assert.ok(!origin.stdout.includes(FAKE_OAUTH_TOKEN));
    const gitConfig = spawnSync("git", ["config", "--local", "--list"], {
      cwd: result.dest,
      encoding: "utf8",
    });
    assert.ok(!gitConfig.stdout.includes(FAKE_OAUTH_TOKEN));
    assert.doesNotMatch(gitConfig.stdout, /extraHeader|x-access-token|Authorization/i);
    const snap = await snapshotCheckout(result.dest);
    assert.match(formatLocalContext(snap), /Local checkout/);
    assert.match(formatLocalContext(snap), /Initial widget/);
  });

  it("replaces a leftover non-git dest so clone can land", async () => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), "wenxiang-src-"));
    const workspace = await mkdtemp(path.join(os.tmpdir(), "wenxiang-ws-"));
    git(["init", "-b", "main"], tmp);
    git(["config", "user.email", "test@example.com"], tmp);
    git(["config", "user.name", "Test"], tmp);
    await writeFile(path.join(tmp, "README.md"), "# recovered\n");
    git(["add", "."], tmp);
    git(["commit", "-m", "Recover"], tmp);

    const dest = path.join(workspace, "acme", "widget");
    await mkdir(dest, { recursive: true });
    await writeFile(path.join(dest, "stale.txt"), "partial clone leftover");

    const result = await ensureCheckout({
      workspaceRoot: workspace,
      owner: "acme",
      repo: "widget",
      cloneUrl: tmp,
      token: FAKE_OAUTH_TOKEN,
      defaultBranch: "main",
    });
    assert.equal(result.local.present, true);
    assert.ok(result.local.files.includes("README.md"));
    assert.match(result.dest, /acme\/widget$/);
  });
});
