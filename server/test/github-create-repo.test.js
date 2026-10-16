import assert from "node:assert/strict";
import { afterEach, describe, it } from "node:test";
import { createUserRepo, validateNewRepoName } from "../src/github.js";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("validateNewRepoName", () => {
  it("accepts a normal name", () => {
    assert.equal(validateNewRepoName("  hello-world "), "hello-world");
    assert.equal(validateNewRepoName("问象"), "问象");
  });

  it("rejects blank and unsafe names", () => {
    assert.throws(() => validateNewRepoName("  "), /请填写仓库名/);
    assert.throws(() => validateNewRepoName("my repo"), /仓库名/);
    assert.throws(() => validateNewRepoName(".hidden"), /仓库名/);
    assert.throws(() => validateNewRepoName("notes.git"), /仓库名/);
    assert.throws(() => validateNewRepoName("CON"), /仓库名/);
  });
});

describe("createUserRepo", () => {
  it("posts a private auto-init repo and returns the summary", async () => {
    let sent = null;
    globalThis.fetch = async (_url, init) => {
      sent = JSON.parse(init.body);
      return new Response(
        JSON.stringify({
          id: 9,
          name: "fresh",
          full_name: "octo/fresh",
          private: true,
          description: "笔记",
          default_branch: "main",
          html_url: "https://github.com/octo/fresh",
          owner: { login: "octo" },
        }),
        { status: 201, headers: { "Content-Type": "application/json" } },
      );
    };
    const repo = await createUserRepo("token", {
      name: "fresh",
      description: "笔记",
      private: true,
    });
    assert.equal(sent.name, "fresh");
    assert.equal(sent.private, true);
    assert.equal(sent.auto_init, true);
    assert.equal(repo.fullName, "octo/fresh");
    assert.equal(repo.owner, "octo");
    assert.equal(repo.private, true);
  });

  it("maps a duplicate name to a Chinese error", async () => {
    globalThis.fetch = async () =>
      new Response(
        JSON.stringify({
          message: "Repository creation failed.",
          errors: [{ message: "name already exists on this account" }],
        }),
        { status: 422, headers: { "Content-Type": "application/json" } },
      );
    await assert.rejects(
      () => createUserRepo("token", { name: "fresh" }),
      (err) => err.status === 409 && err.code === "repo_exists" && /已经有了/.test(err.message),
    );
  });
});
