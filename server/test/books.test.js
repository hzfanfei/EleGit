import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import AdmZip from "adm-zip";
import { describe, it } from "node:test";
import {
  bookIdFromFilename,
  booksDir,
  ensureBookMaterialized,
  listBooks,
  parseEpubBuffer,
  resolveBook,
} from "../src/books.js";

function makeSampleEpub(title = "测试书") {
  const zip = new AdmZip();
  zip.addFile(
    "META-INF/container.xml",
    Buffer.from(
      `<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>`,
    ),
  );
  zip.addFile(
    "OEBPS/content.opf",
    Buffer.from(`<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>${title}</dc:title>
    <dc:creator>作者甲</dc:creator>
    <meta name="cover" content="cover-image"/>
  </metadata>
  <manifest>
    <item id="cover-image" href="cover.jpg" media-type="image/jpeg"/>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="ch1"/></spine>
</package>`),
  );
  zip.addFile("OEBPS/cover.jpg", Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
  zip.addFile(
    "OEBPS/chapter1.xhtml",
    Buffer.from("<html><body><p>第一章内容。</p></body></html>"),
  );
  return zip.toBuffer();
}

describe("books", () => {
  it("derives book ids from filenames", () => {
    assert.equal(bookIdFromFilename("My Book.epub"), "My_Book");
    assert.equal(bookIdFromFilename("中文书名.epub"), "中文书名");
  });

  it("parses epub metadata and lists books from workspace dir", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-books-"));
    const dir = booksDir(root);
    await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, "sample.epub"), makeSampleEpub("样例书"));
    const parsed = parseEpubBuffer(await readFile(path.join(dir, "sample.epub")), {
      filename: "sample.epub",
    });
    assert.equal(parsed.title, "样例书");
    assert.equal(parsed.author, "作者甲");
    assert.ok(parsed.spine.length >= 1);

    const listed = await listBooks(root);
    assert.equal(listed.books.length, 1);
    assert.equal(listed.books[0].title, "样例书");
    assert.equal(listed.books[0].hasCover, true);

    const book = await resolveBook(root, listed.books[0].id);
    const materialized = await ensureBookMaterialized(root, book);
    const text = await readFile(materialized.textPath, "utf8");
    assert.match(text, /第一章内容/);
  });
});
