import assert from "node:assert/strict";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, it } from "node:test";
import {
  contentTypeForStatic,
  deleteStaticFile,
  listStaticFiles,
  normalizeStaticRelative,
  resolveStaticFile,
  staticContentDisposition,
  staticDir,
  staticDownloadAuthorized,
  staticDownloadUrl,
  staticFilesPrompt,
} from "../src/static-files.js";

describe("static files", () => {
  it("keeps the directory beside books under the workspace", () => {
    const previous = process.env.WENXIANG_STATIC_DIR;
    delete process.env.WENXIANG_STATIC_DIR;
    try {
      assert.equal(staticDir("C:\\问象"), path.join("C:\\问象", "static"));
    } finally {
      if (previous === undefined) delete process.env.WENXIANG_STATIC_DIR;
      else process.env.WENXIANG_STATIC_DIR = previous;
    }
  });

  it("rejects traversal and hidden segments", () => {
    const root = path.join(os.tmpdir(), "wenxiang-static-root");
    assert.throws(() => resolveStaticFile(root, "../secret"), /路径无效/);
    assert.throws(() => resolveStaticFile(root, "pkg/%2e%2e/secret"), /路径无效/);
    assert.throws(() => resolveStaticFile(root, ".env"), /路径无效/);
    assert.throws(() => normalizeStaticRelative("a/../../b"), /路径无效/);
    const ok = resolveStaticFile(root, "demo/app release.apk");
    assert.equal(ok.relative, "demo/app release.apk");
    assert.equal(ok.abs, path.resolve(root, "demo", "app release.apk"));
  });

  it("builds a phone download link and authorizes only that token", () => {
    const url = staticDownloadUrl(
      "https://example.ngrok.dev/",
      "demo/问象.apk",
      "tok en",
    );
    assert.equal(
      url,
      "https://example.ngrok.dev/files/demo/%E9%97%AE%E8%B1%A1.apk?token=tok%20en",
    );
    assert.equal(
      staticDownloadAuthorized({ token: "tok en", staticToken: "tok en", apiKey: "api" }),
      true,
    );
    assert.equal(
      staticDownloadAuthorized({ headerKey: "api", staticToken: "tok en", apiKey: "api" }),
      true,
    );
    assert.equal(
      staticDownloadAuthorized({ token: "api", staticToken: "tok en", apiKey: "api" }),
      false,
    );
  });

  it("marks apk as a download and images as inline", () => {
    assert.equal(contentTypeForStatic("app.apk"), "application/vnd.android.package-archive");
    assert.match(staticContentDisposition("问象.apk", "问象.apk"), /^attachment;/);
    assert.match(staticContentDisposition("shot.png", "shot.png"), /^inline;/);
  });

  it("lists nested files and skips hidden ones", async () => {
    const workspace = await mkdtemp(path.join(os.tmpdir(), "wenxiang-static-"));
    const previous = process.env.WENXIANG_STATIC_DIR;
    const dir = path.join(workspace, "drop");
    process.env.WENXIANG_STATIC_DIR = dir;
    try {
      await mkdir(path.join(dir, "demo"), { recursive: true });
      await writeFile(path.join(dir, "demo", "app.apk"), "apk");
      await writeFile(path.join(dir, ".secret"), "nope");
      const listed = await listStaticFiles(workspace, {
        publicUrl: "https://example.ngrok.dev",
        token: "tok",
      });
      assert.equal(listed.files.length, 1);
      assert.equal(listed.files[0].path, "demo/app.apk");
      assert.equal(listed.files[0].size, 3);
      assert.match(listed.files[0].downloadUrl, /\/files\/demo\/app\.apk\?token=tok$/);
    } finally {
      if (previous === undefined) delete process.env.WENXIANG_STATIC_DIR;
      else process.env.WENXIANG_STATIC_DIR = previous;
    }
  });

  it("deletes a file and rejects traversal", async () => {
    const workspace = await mkdtemp(path.join(os.tmpdir(), "wenxiang-static-del-"));
    const previous = process.env.WENXIANG_STATIC_DIR;
    const dir = path.join(workspace, "drop");
    process.env.WENXIANG_STATIC_DIR = dir;
    try {
      await mkdir(path.join(dir, "demo"), { recursive: true });
      const target = path.join(dir, "demo", "app.apk");
      await writeFile(target, "apk");
      const out = await deleteStaticFile(workspace, "demo/app.apk");
      assert.equal(out.path, "demo/app.apk");
      assert.equal(out.ok, true);
      await assert.rejects(() => deleteStaticFile(workspace, "demo/app.apk"), /文件不存在/);
      await assert.rejects(() => deleteStaticFile(workspace, "../secret"), /路径无效/);
    } finally {
      if (previous === undefined) delete process.env.WENXIANG_STATIC_DIR;
      else process.env.WENXIANG_STATIC_DIR = previous;
    }
  });

  it("gives the agent a directory and a link template", () => {
    const previous = process.env.WENXIANG_STATIC_DIR;
    delete process.env.WENXIANG_STATIC_DIR;
    try {
      const prompt = staticFilesPrompt({
        workspaceRoot: path.join(os.tmpdir(), "问象"),
        publicUrl: "https://example.ngrok.dev/",
        staticToken: "abc",
      });
      assert.match(prompt.dir, /static$/);
      assert.equal(prompt.linkTemplate, "https://example.ngrok.dev/files/<path>?token=abc");
    } finally {
      if (previous === undefined) delete process.env.WENXIANG_STATIC_DIR;
      else process.env.WENXIANG_STATIC_DIR = previous;
    }
  });
});
