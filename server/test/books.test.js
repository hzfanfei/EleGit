import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import AdmZip from "adm-zip";
import { describe, it } from "node:test";
import {
  bookIdFromFilename,
  booksDir,
  clearBookAssetIndex,
  ensureBookMaterialized,
  listBooks,
  parseEpubBuffer,
  resolveBook,
  resolveBookCacheAssetPath,
  readBookChapterMarkdown,
  rewriteBookMarkdownImages,
  rewriteBookMarkdownLinks,
  safeBookCacheAssetRelativePath,
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

function makeHrefFirstManifestEpub() {
  const zip = new AdmZip();
  zip.addFile(
    "META-INF/container.xml",
    Buffer.from(
      `<?xml version="1.0"?><container><rootfiles><rootfile full-path="EPUB/content.opf"/></rootfiles></container>`,
    ),
  );
  zip.addFile(
    "EPUB/content.opf",
    Buffer.from(`<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>属性顺序</dc:title>
  </metadata>
  <manifest>
    <item href="text00001.html" id="id_1" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="id_1"/></spine>
</package>`),
  );
  zip.addFile(
    "EPUB/text00001.html",
    Buffer.from("<html><body><p>正文段落。</p></body></html>"),
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
    const index = await readFile(materialized.indexPath, "utf8");
    assert.match(index, /样例书/);
    assert.match(index, /chapters\//);
    const chapterMd = await readFile(
      path.join(materialized.chaptersDir, "001-chapter1.md"),
      "utf8",
    );
    assert.match(chapterMd, /第一章内容/);
    const readingRaw = await readFile(materialized.readingPath, "utf8");
    const reading = JSON.parse(readingRaw);
    assert.equal(reading.chapters.length, 1);
    assert.equal(reading.chapters[0].file, "001-chapter1.md");
  });

  it("rejects unsafe book asset paths", () => {
    assert.throws(() => safeBookCacheAssetRelativePath("../etc/passwd"));
    assert.throws(() => safeBookCacheAssetRelativePath("extracted/../secret"));
    assert.equal(safeBookCacheAssetRelativePath("extracted/OEBPS/fig.png"), "extracted/OEBPS/fig.png");
  });

  it("resolves book assets under the materialized cache", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-books-asset-"));
    const dir = booksDir(root);
    await mkdir(dir, { recursive: true });
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
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>图</dc:title></metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
    <item id="fig" href="fig.png" media-type="image/png"/>
  </manifest>
  <spine><itemref idref="ch1"/></spine>
</package>`),
    );
    const png = Buffer.from([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
      0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
      0x42, 0x60, 0x82,
    ]);
    zip.addFile("OEBPS/fig.png", png);
    zip.addFile(
      "OEBPS/chapter1.xhtml",
      Buffer.from('<html><body><p>见图。</p><img src="fig.png" alt="示例图"/></body></html>'),
    );
    await writeFile(path.join(dir, "fig.epub"), zip.toBuffer());

    const listed = await listBooks(root);
    const book = await resolveBook(root, listed.books[0].id);
    const materialized = await ensureBookMaterialized(root, book);
    const reading = JSON.parse(await readFile(materialized.readingPath, "utf8"));
    assert.equal(reading.chapters[0].href, "OEBPS/chapter1.xhtml");

    const abs = resolveBookCacheAssetPath(materialized, "extracted/OEBPS/fig.png");
    assert.match(abs, /fig\.png$/);
    const byName = resolveBookCacheAssetPath(materialized, "../Images/fig.png");
    assert.match(byName, /fig\.png$/);
    const md = await readBookChapterMarkdown(materialized, reading.chapters[0].file);
    assert.match(md, /extracted\/OEBPS\/fig\.png|fig\.png|image placeholder/);
  });

  it("rewrites markdown and html image refs onto cached files", async () => {
    const cacheDir = await mkdtemp(path.join(os.tmpdir(), "wx-books-rewrite-"));
    const imageDir = path.join(cacheDir, "extracted", "OEBPS", "Images");
    await mkdir(imageDir, { recursive: true });
    await writeFile(path.join(imageDir, "image00483.jpeg"), Buffer.from([0xff, 0xd8, 0xff, 0xd9]));
    clearBookAssetIndex(cacheDir);
    const md = rewriteBookMarkdownImages(
      '见图 ![{%}](../Images/image00483.jpeg)\n<img src="../Images/image00483.jpeg" class="sgc-4" style="width:85.0%" />',
      { cacheDir },
    );
    assert.match(md, /!\[\]\(extracted\/OEBPS\/Images\/image00483\.jpeg\)/);
    assert.equal(md.includes("<img"), false);
    assert.equal(md.includes("../Images/"), false);
  });

  it("rewrites leftover html anchors to markdown links", () => {
    const md = rewriteBookMarkdownLinks(
      '见 <a href="https://vuejs.org">官网</a> 与 <a href="foo.com?a=1&amp;b=2">foo.com?a=1&amp;b=2</a>',
    );
    assert.match(md, /\[官网\]\(https:\/\/vuejs.org\)/);
    assert.match(md, /\[foo.com\?a=1&b=2\]\(foo.com\?a=1&b=2\)/);
    assert.equal(md.includes("<a "), false);
  });

  it("parses spine when manifest items list href before id", async () => {
    const parsed = parseEpubBuffer(makeHrefFirstManifestEpub(), { filename: "order.epub" });
    assert.equal(parsed.spine.length, 1);
    assert.match(parsed.spine[0], /text00001\.html$/);

    const root = await mkdtemp(path.join(os.tmpdir(), "wx-books-order-"));
    const dir = booksDir(root);
    await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, "order.epub"), makeHrefFirstManifestEpub());
    const listed = await listBooks(root);
    const book = await resolveBook(root, listed.books[0].id);
    const materialized = await ensureBookMaterialized(root, book);
    const reading = JSON.parse(await readFile(materialized.readingPath, "utf8"));
    assert.equal(reading.chapters.length, 1);
  });
});
