import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { Buffer } from "node:buffer";
import AdmZip from "adm-zip";
import { describe, it } from "node:test";
import {
  assertSafeExternalUrl,
  downloadBookFromUrl,
  searchBooks,
  searchOpenLibrary,
} from "../src/books-search.js";

function makeFakeEpubBuffer() {
  const zip = new AdmZip();
  zip.addFile(
    "mimetype",
    Buffer.from("application/epub+zip", "utf8"),
    "mimetype entry",
  );
  zip.addFile(
    "OEBPS/content.opf",
    Buffer.from(
      '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Test</dc:title><dc:creator>Author</dc:creator><dc:language>en</dc:language></metadata><manifest><item id="x" href="x.html" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="x"/></spine></package>',
      "utf8",
    ),
  );
  return zip.toBuffer();
}

function makeFetchReturning(buffer, contentType = "application/epub+zip") {
  return async () => {
    return new Response(buffer, {
      status: 200,
      headers: { "Content-Type": contentType },
    });
  };
}

function makeOpenLibraryJson(docs) {
  return {
    numFound: docs.length,
    start: 0,
    docs,
  };
}

describe("books-search", () => {
  describe("searchOpenLibrary", () => {
    it("parses docs, resolves epub filename via IA metadata, keeps public+ia+epub", async () => {
      const fetchImpl = async (url) => {
        const u = typeof url === "string" ? new URL(url) : url;
        if (u.hostname === "openlibrary.org") {
          return new Response(
            JSON.stringify(
              makeOpenLibraryJson([
                {
                  key: "/works/OL1",
                  title: "Book A",
                  author_name: ["Alice", "Bob"],
                  first_publish_year: 2020,
                  ia: ["book-a-id"],
                  ebook_access: "public",
                },
                {
                  key: "/works/OL2",
                  title: "Book B",
                  author_name: ["Carol"],
                  ia: ["book-b-id"],
                  ebook_access: "borrowable", // 应被过滤
                },
                {
                  key: "/works/OL3",
                  title: "Book C",
                  author_name: [],
                  // 没有 ia — 应被过滤
                  ebook_access: "public",
                },
                {
                  key: "/works/OL4",
                  title: "Book D",
                  author_name: ["Dan"],
                  ia: ["book-d-id"],
                  ebook_access: "public",
                },
              ]),
            ),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        if (u.hostname === "archive.org" && u.pathname.startsWith("/metadata/")) {
          return new Response(
            JSON.stringify({
              files: [
                { name: "book-a-id.pdf", format: "Text PDF" },
                { name: "book-a-id.epub", format: "EPUB" },
                { name: "book-d-id.epub", format: "EPUB" },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        return new Response("not found", { status: 404 });
      };
      const results = await searchOpenLibrary("query", { fetchImpl, limit: 10 });
      assert.equal(results.length, 2);
      assert.deepEqual(
        results.map((r) => r.title),
        ["Book A", "Book D"],
      );
      assert.equal(results[0].source, "openlibrary");
      assert.equal(results[0].format, "epub");
      assert.equal(results[0].author, "Alice, Bob");
      assert.equal(results[0].year, "2020");
      assert.equal(
        results[0].downloadUrl,
        "https://archive.org/download/book-a-id/book-a-id.epub",
      );
      assert.equal(results[0].detailUrl, "https://openlibrary.org/works/OL1");
    });

    it("drops docs whose IA metadata has no epub file", async () => {
      const fetchImpl = async (url) => {
        const u = typeof url === "string" ? new URL(url) : url;
        if (u.hostname === "openlibrary.org") {
          return new Response(
            JSON.stringify(
              makeOpenLibraryJson([
                {
                  key: "/works/OL1",
                  title: "PDF Only",
                  author_name: ["X"],
                  ia: ["pdf-only-id"],
                  ebook_access: "public",
                },
              ]),
            ),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        if (u.hostname === "archive.org") {
          // 只有 PDF，没 epub
          return new Response(
            JSON.stringify({
              files: [{ name: "pdf-only-id.pdf", format: "Text PDF" }],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        return new Response("nope", { status: 404 });
      };
      const results = await searchOpenLibrary("query", { fetchImpl });
      assert.deepEqual(results, []);
    });

    it("uses non-ia epub filename when present", async () => {
      const fetchImpl = async (url) => {
        const u = typeof url === "string" ? new URL(url) : url;
        if (u.hostname === "openlibrary.org") {
          return new Response(
            JSON.stringify(
              makeOpenLibraryJson([
                {
                  key: "/works/OL1",
                  title: "Book With Different Filename",
                  author_name: ["X"],
                  ia: ["id-only"],
                  ebook_access: "public",
                },
              ]),
            ),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        if (u.hostname === "archive.org") {
          return new Response(
            JSON.stringify({
              files: [{ name: "actual-book.epub", format: "EPUB" }],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        return new Response("nope", { status: 404 });
      };
      const results = await searchOpenLibrary("query", { fetchImpl });
      assert.equal(results.length, 1);
      assert.equal(
        results[0].downloadUrl,
        "https://archive.org/download/id-only/actual-book.epub",
      );
    });

    it("returns empty array on empty query without hitting fetch", async () => {
      let called = false;
      const fetchImpl = async () => {
        called = true;
        return new Response("{}", { status: 200 });
      };
      const results = await searchOpenLibrary("   ", { fetchImpl });
      assert.deepEqual(results, []);
      assert.equal(called, false);
    });

    it("throws 502 when upstream returns non-OK", async () => {
      const fetchImpl = async () => new Response("oops", { status: 500 });
      await assert.rejects(
        () => searchOpenLibrary("x", { fetchImpl }),
        (err) => err.status === 502 && err.code === "openlibrary_failed",
      );
    });
  });

  describe("searchBooks aggregation", () => {
    it("merges results from multiple sources, skipping failing ones", async () => {
      const fetchImpl = async (url) => {
        const u = typeof url === "string" ? new URL(url) : url;
        if (u.hostname === "openlibrary.org") {
          return new Response(
            JSON.stringify(
              makeOpenLibraryJson([
                {
                  key: "/works/OL1",
                  title: "OL Book",
                  author_name: ["Author"],
                  ebook_access: "public",
                  ia: ["id-1"],
                },
              ]),
            ),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        if (u.hostname === "archive.org" && u.pathname.startsWith("/metadata/")) {
          return new Response(
            JSON.stringify({ files: [{ name: "id-1.epub", format: "EPUB" }] }),
            { status: 200, headers: { "Content-Type": "application/json" } },
          );
        }
        return new Response("nope", { status: 500 });
      };
      const results = await searchBooks("query", {
        fetchImpl,
        sources: ["openlibrary", "jiumo", "bogus"],
      });
      assert.equal(results.length, 1);
      assert.equal(results[0].title, "OL Book");
    });
  });

  describe("assertSafeExternalUrl", () => {
    it("rejects non-http(s) protocols", async () => {
      await assert.rejects(
        () => assertSafeExternalUrl("ftp://example.com/a.epub"),
        (err) => err.status === 400 && err.code === "bad_protocol",
      );
    });
    it("rejects malformed URLs", async () => {
      await assert.rejects(
        () => assertSafeExternalUrl("not a url"),
        (err) => err.status === 400 && err.code === "bad_url",
      );
    });
    it("rejects loopback IPv4", async () => {
      await assert.rejects(
        () => assertSafeExternalUrl("http://127.0.0.1/a.epub"),
        (err) => err.status === 400 && err.code === "private_ip_blocked",
      );
    });
    it("rejects RFC1918 private IPv4", async () => {
      await assert.rejects(
        () => assertSafeExternalUrl("http://10.0.0.1/a.epub"),
        (err) => err.status === 400 && err.code === "private_ip_blocked",
      );
      await assert.rejects(
        () => assertSafeExternalUrl("http://192.168.1.1/a.epub"),
        (err) => err.status === 400 && err.code === "private_ip_blocked",
      );
      await assert.rejects(
        () => assertSafeExternalUrl("http://172.16.0.1/a.epub"),
        (err) => err.status === 400 && err.code === "private_ip_blocked",
      );
    });
    it("accepts public hostnames (mock DNS)", async () => {
      // 用一个真实存在的公共域名；DNS 解析结果必然是公网 IP
      const url = await assertSafeExternalUrl("https://archive.org/download/x/x.epub");
      assert.equal(url.protocol, "https:");
      assert.equal(url.hostname, "archive.org");
    });
  });

  describe("downloadBookFromUrl", () => {
    async function withWorkspace(fn) {
      const dir = await mkdtemp(path.join(os.tmpdir(), "wx-books-search-"));
      try {
        await fn(dir);
      } finally {
        // 留给 OS 清理
      }
    }

    it("writes a valid epub file into the books dir", async () => {
      await withWorkspace(async (workspaceRoot) => {
        const buf = makeFakeEpubBuffer();
        const fetchImpl = makeFetchReturning(buf, "application/epub+zip");
        const result = await downloadBookFromUrl("https://archive.org/download/x/x.epub", {
          workspaceRoot,
          fetchImpl,
          suggestedTitle: "Test Book",
        });
        assert.ok(result.filename.endsWith(".epub"));
        assert.ok(result.path.endsWith(result.filename));
        assert.ok(result.size > 0);
        // 文件存在且内容合法
        const onDisk = await readFile(result.path);
        assert.equal(onDisk[0], 0x50);
        assert.equal(onDisk[1], 0x4b);
        // 在 booksDir 下
        const expectedDir = path.join(workspaceRoot, "books");
        assert.ok(result.path.startsWith(expectedDir));
      });
    });

    it("rejects text/html responses as not_epub", async () => {
      await withWorkspace(async (workspaceRoot) => {
        const fetchImpl = makeFetchReturning(
          Buffer.from("<html>not an epub</html>"),
          "text/html; charset=utf-8",
        );
        await assert.rejects(
          () =>
            downloadBookFromUrl("https://archive.org/download/x/x.epub", {
              workspaceRoot,
              fetchImpl,
            }),
          (err) => err.status === 415 && err.code === "not_epub",
        );
      });
    });

    it("rejects non-zip binary content", async () => {
      await withWorkspace(async (workspaceRoot) => {
        const fakePdf = Buffer.from("%PDF-1.4 not a zip");
        const fetchImpl = makeFetchReturning(fakePdf, "application/octet-stream");
        await assert.rejects(
          () =>
            downloadBookFromUrl("https://archive.org/download/x/x.epub", {
              workspaceRoot,
              fetchImpl,
            }),
          (err) => err.status === 415 && err.code === "not_epub",
        );
      });
    });

    it("renames on collision without overwriting", async () => {
      await withWorkspace(async (workspaceRoot) => {
        // 先建好 books 目录并存一个"会被归一化到同一文件名"的旧 epub
        const booksPath = path.join(workspaceRoot, "books");
        await mkdir(booksPath, { recursive: true });
        // bookIdFromFilename("Test Book.epub") 会把空格换成下划线 → "Test_Book.epub"
        await writeFile(path.join(booksPath, "Test_Book.epub"), Buffer.from("OLD"));

        const buf = makeFakeEpubBuffer();
        const fetchImpl = makeFetchReturning(buf, "application/epub+zip");
        const result = await downloadBookFromUrl("https://archive.org/download/x/x.epub", {
          workspaceRoot,
          fetchImpl,
          suggestedTitle: "Test Book",
        });
        assert.notEqual(result.filename, "Test_Book.epub");
        assert.match(result.filename, /^Test_Book-\d+\.epub$/);
        const old = await readFile(path.join(booksPath, "Test_Book.epub"));
        assert.equal(old.toString("utf8"), "OLD");
      });
    });

    it("creates the books dir if missing", async () => {
      const dir = await mkdtemp(path.join(os.tmpdir(), "wx-books-search-empty-"));
      const buf = makeFakeEpubBuffer();
      const fetchImpl = makeFetchReturning(buf, "application/epub+zip");
      const result = await downloadBookFromUrl("https://archive.org/download/x/x.epub", {
        workspaceRoot: dir,
        fetchImpl,
        suggestedTitle: "Hello",
      });
      assert.ok(result.path.startsWith(path.join(dir, "books")));
    });
  });
});