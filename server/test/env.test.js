import assert from "node:assert/strict";
import { mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import { loadLocalEnv } from "../src/env.js";
import { loadStore, resolveGithubToken } from "../src/store.js";

describe("loadLocalEnv", () => {
  it("fills empty process env from a local .env file and does not override", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "wenxiang-env-"));
    const file = path.join(dir, ".env");
    await writeFile(file, "GITHUB_CLIENT_ID=example-from-file\nGITHUB_CLIENT_SECRET=example-secret-from-file\n");

    const previousId = process.env.GITHUB_CLIENT_ID;
    const previousSecret = process.env.GITHUB_CLIENT_SECRET;
    delete process.env.GITHUB_CLIENT_ID;
    delete process.env.GITHUB_CLIENT_SECRET;
    try {
      const missing = loadLocalEnv(path.join(dir, "nope.env"));
      assert.equal(missing.loaded, false);

      const loaded = loadLocalEnv(file);
      assert.equal(loaded.loaded, true);
      assert.equal(process.env.GITHUB_CLIENT_ID, "example-from-file");

      process.env.GITHUB_CLIENT_ID = "example-from-process";
      loadLocalEnv(file);
      assert.equal(process.env.GITHUB_CLIENT_ID, "example-from-process");
    } finally {
      if (previousId === undefined) delete process.env.GITHUB_CLIENT_ID;
      else process.env.GITHUB_CLIENT_ID = previousId;
      if (previousSecret === undefined) delete process.env.GITHUB_CLIENT_SECRET;
      else process.env.GITHUB_CLIENT_SECRET = previousSecret;
    }
  });
});

describe("OAuth client precedence", () => {
  it("uses env over ~/.wenxiang config.json", async () => {
    const home = await mkdtemp(path.join(os.tmpdir(), "wenxiang-home-"));
    await writeFile(
      path.join(home, "config.json"),
      JSON.stringify({
        apiKey: "test-key",
        githubClientId: "example-from-config",
        githubClientSecret: "example-secret-from-config",
      }),
    );
    const previousId = process.env.GITHUB_CLIENT_ID;
    const previousSecret = process.env.GITHUB_CLIENT_SECRET;
    process.env.GITHUB_CLIENT_ID = "example-from-env";
    process.env.GITHUB_CLIENT_SECRET = "example-secret-from-env";
    try {
      const store = await loadStore(home);
      assert.equal(store.config.githubClientId, "example-from-env");
    } finally {
      if (previousId === undefined) delete process.env.GITHUB_CLIENT_ID;
      else process.env.GITHUB_CLIENT_ID = previousId;
      if (previousSecret === undefined) delete process.env.GITHUB_CLIENT_SECRET;
      else process.env.GITHUB_CLIENT_SECRET = previousSecret;
    }
  });

  it("reads OAuth client fields from config.json when env is empty", async () => {
    const home = await mkdtemp(path.join(os.tmpdir(), "wenxiang-home-"));
    await writeFile(
      path.join(home, "config.json"),
      JSON.stringify({
        apiKey: "test-key",
        githubClientId: "example-from-config",
        githubClientSecret: "example-secret-from-config",
      }),
    );
    const previousId = process.env.GITHUB_CLIENT_ID;
    const previousSecret = process.env.GITHUB_CLIENT_SECRET;
    delete process.env.GITHUB_CLIENT_ID;
    delete process.env.GITHUB_CLIENT_SECRET;
    try {
      const store = await loadStore(home);
      assert.equal(store.config.githubClientId, "example-from-config");
    } finally {
      if (previousId === undefined) delete process.env.GITHUB_CLIENT_ID;
      else process.env.GITHUB_CLIENT_ID = previousId;
      if (previousSecret === undefined) delete process.env.GITHUB_CLIENT_SECRET;
      else process.env.GITHUB_CLIENT_SECRET = previousSecret;
    }
  });
});

describe("GitHub session restore", () => {
  it("treats a token already in ~/.wenxiang as a connected session", async () => {
    const home = await mkdtemp(path.join(os.tmpdir(), "wenxiang-home-"));
    await writeFile(
      path.join(home, "config.json"),
      JSON.stringify({
        apiKey: "test-key",
        githubToken: "gho_existing_session_token",
        githubUser: { login: "octo" },
      }),
    );
    const store = await loadStore(home);
    assert.equal(store.config.githubToken, "gho_existing_session_token");
    assert.equal(resolveGithubToken(store.config), "gho_existing_session_token");
  });

  it("picks up PAT aliases used in ~/.wenxiang config.json", () => {
    assert.equal(
      resolveGithubToken({ github_token: "github_pat_alias" }),
      "github_pat_alias",
    );
    assert.equal(resolveGithubToken({ token: "gho_plain" }), "gho_plain");
    assert.equal(resolveGithubToken({ githubToken: "" }, { GITHUB_TOKEN: "gho_from_env" }), "gho_from_env");
  });
});
