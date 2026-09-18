import assert from "node:assert/strict";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import AdmZip from "adm-zip";
import { describe, it } from "node:test";
import {
  booksDir,
  chapterSliceHtmlPath,
  chooseBookToc,
  ensureBookMaterialized,
  listBooks,
  parseNavTocFromHtml,
  parseNcxToc,
  resolveBook,
  splitHtmlByAnchorIds,
} from "../src/books.js";

function makeNavFirstNcxFragmentEpub() {
  const zip = new AdmZip();
  zip.addFile(
    "META-INF/container.xml",
    Buffer.from(
      '<?xml version="1.0"?><container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>',
    ),
  );
  zip.addFile(
    "OEBPS/content.opf",
    Buffer.from(`<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>导航优先</dc:title>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
    <item id="part" href="Text/part0000.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine toc="ncx"><itemref idref="part"/></spine>
</package>`),
  );
  zip.addFile(
    "OEBPS/nav.xhtml",
    Buffer.from(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><nav epub:type="toc"><ol><li><a href="Text/part0000.xhtml">正文</a></li></ol></nav></body></html>',
    ),
  );
  zip.addFile(
    "OEBPS/toc.ncx",
    Buffer.from(`<?xml version="1.0"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <navMap>
    <navPoint id="n1" playOrder="1">
      <navLabel><text>版权信息</text></navLabel>
      <content src="Text/part0000.xhtml"/>
    </navPoint>
    <navPoint id="n2" playOrder="2">
      <navLabel><text>序</text></navLabel>
      <content src="Text/part0000.xhtml#nav_point_0"/>
    </navPoint>
    <navPoint id="n3" playOrder="3">
      <navLabel><text>第 1 章</text></navLabel>
      <content src="Text/part0000.xhtml#nav_point_8"/>
    </navPoint>
  </navMap>
</ncx>`),
  );
  zip.addFile(
    "OEBPS/Text/part0000.xhtml",
    Buffer.from(
      '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>版权页</p><h1 id="nav_point_0">序</h1><p>序文</p><h1 id="nav_point_8">第 1 章</h1><p>正文</p></body></html>',
    ),
  );
  return zip.toBuffer();
}

describe("book toc split", () => {
  it("parses ncx content when src is not the first attribute", () => {
    const toc = parseNcxToc(
      '<navMap><navPoint id="n2"><navLabel><text>序</text></navLabel><content id="n2" src="Text/part0000.xhtml#nav_point_0"/></navPoint></navMap>',
    );
    assert.equal(toc.length, 1);
    assert.equal(toc[0].title, "序");
    assert.equal(toc[0].fragment, "nav_point_0");
  });

  it("parses nav href hashes and prefers ncx when nav has no fragments", () => {
    const nav = parseNavTocFromHtml(
      '<nav epub:type="toc"><ol><li><a href="Text/part0000.xhtml#nav_point_0">序</a></li><li><a href="Text/part0000.xhtml#nav_point_8">第 1 章</a></li></ol></nav>',
    );
    assert.equal(nav[0].fragment, "nav_point_0");
    assert.equal(nav[1].fragment, "nav_point_8");

    const navWhole = [{ title: "正文", href: "Text/part0000.xhtml", fragment: "" }];
    const ncx = [
      { title: "序", href: "Text/part0000.xhtml", fragment: "nav_point_0" },
      { title: "第 1 章", href: "Text/part0000.xhtml", fragment: "nav_point_8" },
    ];
    const chosen = chooseBookToc(navWhole, ncx);
    assert.equal(chosen[0].fragment, "nav_point_0");
    assert.equal(chosen.length, 2);
  });

  it("splits on name anchors used by older epub2 files", () => {
    const slices = splitHtmlByAnchorIds(
      '<p>版权页</p><a name="nav_point_0"></a><h1>序</h1><p>序文</p>',
      ["nav_point_0"],
    );
    assert.equal(slices.length, 2);
    assert.match(slices[0].html, /版权页/);
    assert.equal(slices[1].id, "nav_point_0");
    assert.match(slices[1].html, /序文/);
  });

  it("writes slice html beside the spine file so relative images resolve", () => {
    const spine = path.join("C:", "cache", "extracted", "OEBPS", "Text", "part0000.xhtml");
    const input = chapterSliceHtmlPath(spine, "003-nav_point_8.md");
    assert.equal(path.dirname(input), path.dirname(spine));
    assert.match(path.basename(input), /^\._wx-in-003-nav_point_8\.md\.xhtml$/);
  });

  it("still splits when an epub3 nav exists without hashes", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "wx-books-nav-"));
    const dir = booksDir(root);
    await mkdir(dir, { recursive: true });
    await writeFile(path.join(dir, "nav-first.epub"), makeNavFirstNcxFragmentEpub());
    const listed = await listBooks(root);
    const book = await resolveBook(root, listed.books[0].id);
    const materialized = await ensureBookMaterialized(root, book);
    const reading = JSON.parse(await readFile(materialized.readingPath, "utf8"));
    const titles = reading.chapters.map((c) => c.title);
    assert.ok(titles.includes("序"));
    assert.ok(titles.includes("第 1 章"));
    assert.ok(reading.chapters.length >= 3);
  });
});
