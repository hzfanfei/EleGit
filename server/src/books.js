import { createHash } from "node:crypto";
import { createReadStream, existsSync, readdirSync, statSync } from "node:fs";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import AdmZip from "adm-zip";
import { findPandoc, htmlToMarkdown } from "./pandoc.js";
import { defaultWorkspaceRoot } from "./workspace.js";

const BOOK_OWNER = "_book";
const DEFAULT_BOOK_TEXT_MAX = 1_000_000;
const MATERIALIZE_VERSION = 2;

export function bookTextMaxChars(env = process.env) {
  const raw = String(env.WENXIANG_BOOK_TEXT_MAX_CHARS || String(DEFAULT_BOOK_TEXT_MAX)).trim();
  const n = Number.parseInt(raw, 10);
  return Number.isFinite(n) && n > 0 ? n : DEFAULT_BOOK_TEXT_MAX;
}

function titleFromHtml(html) {
  const h1 = String(html || "").match(/<h1[^>]*>([\s\S]*?)<\/h1>/i);
  if (h1?.[1]) {
    const t = stripHtml(h1[1]).trim();
    if (t) return t.slice(0, 160);
  }
  const t = firstTag(html, "title");
  if (t) return t.slice(0, 160);
  return "";
}

function titleFromMarkdown(md) {
  for (const line of String(md || "").split("\n")) {
    const m = line.match(/^#\s+(.+)/);
    if (m?.[1]) {
      const title = sanitizeBookDisplayTitle(m[1]);
      if (title) return title;
    }
  }
  return "";
}

function normalizeEpubHref(href) {
  return decodeXml(String(href || "").split("#")[0].trim())
    .replace(/^\.\//, "")
    .replace(/\\/g, "/")
    .toLowerCase();
}

function findNavDocumentHref(opf, opfDir) {
  for (const block of opf.matchAll(/<item\b([^>]+)\/?>/gi)) {
    const attrs = block[1];
    if (!/\bproperties=["'][^"']*\bnav\b/i.test(attrs)) continue;
    const hrefM = attrs.match(/\bhref=["']([^"']+)["']/i);
    if (hrefM?.[1]) {
      return path.posix.join(opfDir, hrefM[1]).replace(/\\/g, "/");
    }
  }
  return "";
}

function parseNavListHtml(html, level, out) {
  const re = /<li(?:\s[^>]*)?>([\s\S]*?)<\/li>/gi;
  let match;
  while ((match = re.exec(html)) !== null) {
    const body = match[1];
    const link = body.match(/<a\b[^>]*\bhref=["']([^"']+)["'][^>]*>([\s\S]*?)<\/a>/i);
    if (link) {
      const title = stripHtml(link[2]).trim();
      if (title) {
        out.push({ href: link[1], title: title.slice(0, 160), level });
      }
    }
    const nested = body.match(/<ol[^>]*>([\s\S]*?)<\/ol>/i);
    if (nested?.[1]) parseNavListHtml(nested[1], level + 1, out);
  }
}

function parseNavTocFromHtml(html) {
  const block =
    html.match(
      /<nav[^>]*(?:epub:type=["'][^"']*toc[^"']*["']|role=["']doc-toc["'])[^>]*>([\s\S]*?)<\/nav>/i,
    )?.[1] || html.match(/<nav[^>]*>([\s\S]*?)<\/nav>/i)?.[1];
  if (!block) return [];
  const ol = block.match(/<ol[^>]*>([\s\S]*?)<\/ol>/i)?.[1] || block;
  const out = [];
  parseNavListHtml(ol, 0, out);
  return out;
}

function spineIndexForHref(spine, href) {
  const norm = normalizeEpubHref(href);
  const idx = spine.findIndex((h) => normalizeEpubHref(h) === norm);
  if (idx >= 0) return idx;
  const base = path.posix.basename(norm);
  return spine.findIndex((h) => path.posix.basename(normalizeEpubHref(h)) === base);
}

function escapeRegExp(value) {
  return String(value || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function parseNcxToc(ncx) {
  const src = String(ncx || "");
  const out = [];
  let depth = 0;
  const token =
    /<\/navPoint>|<navPoint\b[^>]*>|<navLabel>\s*<text>([\s\S]*?)<\/text>\s*<\/navLabel>\s*<content\s+src=["']([^"']+)["'][^>]*\/?>/gi;
  let match;
  while ((match = token.exec(src))) {
    const raw = match[0];
    if (raw.startsWith("</navPoint")) {
      depth = Math.max(0, depth - 1);
      continue;
    }
    if (/^<navPoint\b/i.test(raw)) {
      depth += 1;
      continue;
    }
    const title = decodeXml(String(match[1] || "").replace(/<[^>]+>/g, "")).trim();
    const hrefRaw = decodeXml(String(match[2] || "").trim()).replace(/\\/g, "/");
    const hash = hrefRaw.indexOf("#");
    const file = hash >= 0 ? hrefRaw.slice(0, hash) : hrefRaw;
    const fragment = hash >= 0 ? hrefRaw.slice(hash + 1).trim() : "";
    if (!title) continue;
    out.push({
      title,
      href: file,
      fragment,
      level: Math.max(0, depth - 1),
    });
  }
  return out;
}

export function splitHtmlByAnchorIds(html, ids) {
  const raw = String(html || "");
  const points = [];
  const seen = new Set();
  for (const id of ids) {
    const key = String(id || "").trim();
    if (!key || seen.has(key)) continue;
    seen.add(key);
    const re = new RegExp(`\\sid=["']${escapeRegExp(key)}["']`, "i");
    const found = re.exec(raw);
    if (!found) continue;
    let start = raw.lastIndexOf("<", found.index);
    if (start < 0) start = found.index;
    points.push({ id: key, start });
  }
  points.sort((a, b) => a.start - b.start);
  if (!points.length) return [{ id: "", html: raw }];
  const slices = [];
  if (points[0].start > 0) {
    const head = raw.slice(0, points[0].start);
    if (stripHtml(head).trim()) slices.push({ id: "", html: head });
  }
  for (let i = 0; i < points.length; i += 1) {
    const end = i + 1 < points.length ? points[i + 1].start : raw.length;
    slices.push({ id: points[i].id, html: raw.slice(points[i].start, end) });
  }
  return slices;
}

function findNcxDocumentHref(opf, opfDir) {
  const item =
    String(opf || "").match(/<item\b[^>]*media-type=["']application\/x-dtbncx\+xml["'][^>]*>/i)?.[0] ||
    String(opf || "").match(/<item\b[^>]*href=["'][^"']*\.ncx["'][^>]*>/i)?.[0] ||
    "";
  const href = item.match(/\bhref=["']([^"']+)["']/i)?.[1];
  if (!href) return "";
  return path.posix.join(opfDir, href).replace(/\\/g, "/");
}

function sameSpineFile(tocHref, spineHref) {
  return path.posix.basename(normalizeEpubHref(tocHref)) === path.posix.basename(normalizeEpubHref(spineHref));
}

async function loadEpubNavToc(extractedDir, opf, opfDir, spine) {
  const navHref = findNavDocumentHref(opf, opfDir);
  if (navHref) {
    const abs = resolvePath(extractedDir, navHref);
    if (abs && abs.startsWith(extractedDir)) {
      try {
        const html = await readFile(abs, "utf8");
        const raw = parseNavTocFromHtml(html);
        const toc = [];
        for (const item of raw) {
          const index = spineIndexForHref(spine, item.href);
          if (index < 0) continue;
          toc.push({ index, title: item.title, level: item.level, href: item.href, fragment: "" });
        }
        if (toc.length) return toc;
      } catch {
        // fall through to NCX
      }
    }
  }
  const ncxHref = findNcxDocumentHref(opf, opfDir);
  if (!ncxHref) return [];
  const ncxAbs = resolvePath(extractedDir, ncxHref);
  if (!ncxAbs || !ncxAbs.startsWith(extractedDir)) return [];
  try {
    return parseNcxToc(await readFile(ncxAbs, "utf8"));
  } catch {
    return [];
  }
}

function chapterMarkdownBasename(index, href) {
  const stem = path
    .basename(String(href || "chapter"), path.extname(String(href || "")))
    .replace(/[^\w\u4e00-\u9fff-]+/g, "_")
    .replace(/^_+|_+$/g, "")
    .slice(0, 48);
  const num = String(index + 1).padStart(3, "0");
  return `${num}-${stem || "chapter"}.md`;
}

export function booksDir(workspaceRoot = defaultWorkspaceRoot()) {
  const custom = String(process.env.WENXIANG_BOOKS_DIR || "").trim();
  if (custom) return path.resolve(custom);
  return path.join(workspaceRoot, "books");
}

export function bookCacheRoot(workspaceRoot = defaultWorkspaceRoot()) {
  return path.join(workspaceRoot, ".book-cache");
}

export function bookCacheDir(workspaceRoot, bookId) {
  return path.join(bookCacheRoot(workspaceRoot), safeBookSegment(bookId, "bookId"));
}

function safeBookSegment(name, label) {
  const text = String(name || "").trim();
  if (!text || text === "." || text === ".." || /[\\/]/.test(text)) {
    const err = new Error(`Invalid ${label}`);
    err.status = 400;
    throw err;
  }
  return text;
}

function decodeXml(text) {
  return String(text || "")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

function firstTag(xml, tag) {
  const re = new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, "i");
  const match = String(xml || "").match(re);
  return match ? decodeXml(match[1].trim()) : "";
}

function attrTag(xml, tag, attr) {
  const re = new RegExp(`<${tag}[^>]*\\s${attr}=["']([^"']+)["']`, "i");
  const match = String(xml || "").match(re);
  return match ? decodeXml(match[1].trim()) : "";
}

function stripHtml(html) {
  return decodeXml(
    String(html || "")
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/p>/gi, "\n")
      .replace(/<[^>]+>/g, " ")
      .replace(/\s+\n/g, "\n")
      .replace(/[ \t]{2,}/g, " ")
      .trim(),
  );
}

function resolvePath(baseDir, href) {
  const raw = decodeXml(href.split("#")[0].trim());
  if (!raw || raw.startsWith("http://") || raw.startsWith("https://")) return "";
  const segments = raw.replace(/\\/g, "/").split("/").filter(Boolean);
  const joined = path.normalize(path.join(baseDir, ...segments));
  const base = path.normalize(baseDir);
  if (!joined.startsWith(base)) return "";
  return joined;
}

function readZipText(zip, entryPath) {
  const entry = zip.getEntry(entryPath.replace(/^\//, ""));
  if (!entry) return "";
  return zip.readAsText(entry, "utf8");
}

function readZipBuffer(zip, entryPath) {
  const entry = zip.getEntry(entryPath.replace(/^\//, ""));
  if (!entry) return null;
  return zip.readFile(entry);
}

/** Map manifest item id → href (attribute order in OPF varies). */
function parseOpfManifestHrefs(opf) {
  const map = new Map();
  for (const match of String(opf || "").matchAll(/<item\b([^>]+)\/?>/gi)) {
    const attrs = match[1];
    const id = attrs.match(/\bid=["']([^"']+)["']/i)?.[1];
    const href = attrs.match(/\bhref=["']([^"']+)["']/i)?.[1];
    if (id && href) map.set(id, href);
  }
  return map;
}

export function parseEpubBuffer(buffer, { filename = "book.epub" } = {}) {
  const zip = new AdmZip(buffer);
  const container = readZipText(zip, "META-INF/container.xml");
  const rootfile = attrTag(container, "rootfile", "full-path") || "OEBPS/content.opf";
  const opfPath = rootfile.replace(/^\//, "");
  const opfDir = path.posix.dirname(opfPath);
  const opf = readZipText(zip, opfPath);
  const title =
    firstTag(opf, "dc:title") ||
    firstTag(opf, "title") ||
    path.basename(filename, path.extname(filename));
  const author = firstTag(opf, "dc:creator") || firstTag(opf, "creator") || "";
  const language = firstTag(opf, "dc:language") || firstTag(opf, "language") || "";

  let coverHref = "";
  const coverMeta = opf.match(/<meta[^>]+name=["']cover["'][^>]+content=["']([^"']+)["']/i);
  if (coverMeta?.[1]) {
    const coverId = coverMeta[1];
    const itemRe = new RegExp(
      `<item[^>]+id=["']${coverId}["'][^>]+href=["']([^"']+)["']`,
      "i",
    );
    const itemMatch = opf.match(itemRe);
    if (itemMatch?.[1]) {
      coverHref = path.posix.join(opfDir, itemMatch[1]).replace(/\\/g, "/");
    }
  }
  if (!coverHref) {
    const propsCover = opf.match(/<item[^>]+properties=["'][^"']*cover-image[^"']*["'][^>]+href=["']([^"']+)["']/i);
    if (propsCover?.[1]) {
      coverHref = path.posix.join(opfDir, propsCover[1]).replace(/\\/g, "/");
    }
  }

  const manifestHrefs = parseOpfManifestHrefs(opf);
  const spine = [];
  const spineBlock = opf.match(/<spine[^>]*>([\s\S]*?)<\/spine>/i)?.[1] || "";
  for (const match of spineBlock.matchAll(/<itemref[^>]+idref=["']([^"']+)["']/gi)) {
    const idref = match[1];
    const href = manifestHrefs.get(idref);
    if (href) {
      spine.push(path.posix.join(opfDir, href).replace(/\\/g, "/"));
    }
  }

  let coverBuffer = null;
  let coverExt = "";
  if (coverHref) {
    coverBuffer = readZipBuffer(zip, coverHref);
    coverExt = path.extname(coverHref).toLowerCase();
  }

  return {
    title,
    author,
    language,
    opfPath,
    spine,
    coverHref,
    coverBuffer,
    coverExt,
    zip,
  };
}

export function bookIdFromFilename(filename) {
  const base = path.basename(filename, path.extname(filename));
  const safe = base
    .replace(/[^\w\u4e00-\u9fff.-]+/g, "_")
    .replace(/_+/g, "_")
    .replace(/^_|_$/g, "")
    .slice(0, 96);
  return safe || "book";
}

function uniqueBookId(desired, used) {
  let id = desired;
  let n = 2;
  while (used.has(id)) {
    id = `${desired}-${n}`;
    n += 1;
  }
  used.add(id);
  return id;
}

export async function listBooks(workspaceRoot) {
  const dir = booksDir(workspaceRoot);
  await mkdir(dir, { recursive: true });
  let names = [];
  try {
    names = await readdir(dir);
  } catch {
    names = [];
  }
  const used = new Set();
  const books = [];
  for (const name of names.sort((a, b) => a.localeCompare(b, "zh-CN"))) {
    if (!/\.epub$/i.test(name)) continue;
    const abs = path.join(dir, name);
    let st;
    try {
      st = await stat(abs);
    } catch {
      continue;
    }
    if (!st.isFile()) continue;
    const id = uniqueBookId(bookIdFromFilename(name), used);
    let meta = { title: path.basename(name, ".epub"), author: "", language: "", hasCover: false };
    try {
      const buf = await readFile(abs);
      const parsed = parseEpubBuffer(buf, { filename: name });
      meta = {
        title: parsed.title || meta.title,
        author: parsed.author,
        language: parsed.language,
        hasCover: Boolean(parsed.coverBuffer?.length),
      };
    } catch {
      // keep filename title
    }
    books.push({
      id,
      filename: name,
      title: meta.title,
      author: meta.author,
      language: meta.language,
      size: st.size,
      modifiedAt: st.mtime.toISOString(),
      hasCover: meta.hasCover,
    });
  }
  return { dir, books };
}

export async function resolveBook(workspaceRoot, bookId) {
  const { dir, books } = await listBooks(workspaceRoot);
  const book = books.find((b) => b.id === bookId);
  if (!book) {
    const err = new Error("Book not found");
    err.status = 404;
    throw err;
  }
  return { ...book, path: path.join(dir, book.filename), booksDir: dir };
}

export async function ensureBookMaterialized(workspaceRoot, book) {
  const cacheDir = bookCacheDir(workspaceRoot, book.id);
  const extractedDir = path.join(cacheDir, "extracted");
  const textPath = path.join(cacheDir, "text.txt");
  const metaPath = path.join(cacheDir, "meta.json");
  const coverPath = path.join(cacheDir, "cover");
  await mkdir(extractedDir, { recursive: true });

  const srcMtime = (await stat(book.path)).mtimeMs;
  let cachedMtime = 0;
  let cachedVersion = 0;
  try {
    const metaRaw = await readFile(metaPath, "utf8");
    const meta = JSON.parse(metaRaw);
    cachedMtime = Number(meta.sourceMtime) || 0;
    cachedVersion = Number(meta.materializeVersion) || 0;
  } catch {
    cachedMtime = 0;
    cachedVersion = 0;
  }

  const chaptersDir = path.join(cacheDir, "chapters");
  const indexPath = path.join(cacheDir, "INDEX.md");
  const readingPath = path.join(cacheDir, "reading.json");
  let cachedChapterCount = 0;
  if (existsSync(readingPath)) {
    try {
      const cached = JSON.parse(await readFile(readingPath, "utf8"));
      cachedChapterCount = Array.isArray(cached.chapters) ? cached.chapters.length : 0;
    } catch {
      cachedChapterCount = 0;
    }
  }
  if (
    cachedMtime === srcMtime &&
    cachedVersion >= MATERIALIZE_VERSION &&
    existsSync(textPath) &&
    existsSync(indexPath) &&
    existsSync(readingPath) &&
    cachedChapterCount > 0
  ) {
    return {
      cacheDir,
      extractedDir,
      textPath,
      coverPath,
      chaptersDir,
      indexPath,
      readingPath,
      fresh: false,
    };
  }

  clearBookAssetIndex(cacheDir);
  const buffer = await readFile(book.path);
  const parsed = parseEpubBuffer(buffer, { filename: book.filename });
  const zip = parsed.zip;
  for (const entry of zip.getEntries()) {
    if (entry.isDirectory) continue;
    const name = entry.entryName.replace(/\\/g, "/");
    if (name.startsWith("..")) continue;
    const dest = path.join(extractedDir, name);
    await mkdir(path.dirname(dest), { recursive: true });
    await writeFile(dest, zip.readFile(entry));
  }

  const opf = readZipText(parsed.zip, parsed.opfPath || "OEBPS/content.opf");
  const opfDir = path.posix.dirname(String(parsed.opfPath || "OEBPS/content.opf").replace(/^\//, ""));
  const navToc = await loadEpubNavToc(extractedDir, opf, opfDir, parsed.spine);
  const navTitleByIndex = new Map();
  for (const item of navToc) {
    if (!navTitleByIndex.has(item.index)) {
      navTitleByIndex.set(item.index, { title: item.title, level: item.level });
    }
  }

  const chunks = [];
  const chapterFiles = [];
  await mkdir(chaptersDir, { recursive: true });
  const pandocPath = findPandoc();
  const mediaDir = path.join(cacheDir, "media");
  let chapterIndex = 0;

  async function writeChapterSlice({ sliceHtml, sourceHref, fragment, hint, htmlPath }) {
    const text = stripHtml(sliceHtml);
    if (!text) return;
    chunks.push(text);
    const fname = chapterMarkdownBasename(chapterIndex, fragment || sourceHref);
    const outPath = path.join(chaptersDir, fname);
    let converted = false;
    if (pandocPath) {
      let inputPath = htmlPath;
      if (!inputPath) {
        inputPath = path.join(chaptersDir, `._in-${fname}.xhtml`);
        await writeFile(
          inputPath,
          `<!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><body>${sliceHtml}</body></html>`,
          "utf8",
        );
      }
      converted = await htmlToMarkdown({
        htmlPath: inputPath,
        outPath,
        pandocPath,
        extractMediaDir: mediaDir,
      });
    }
    if (!converted) {
      const fallbackTitle = hint?.title || titleFromHtml(sliceHtml) || `第 ${chapterIndex + 1} 章`;
      await writeFile(outPath, `# ${fallbackTitle}\n\n${text}\n`, "utf8");
    }
    let mdBody = "";
    try {
      mdBody = await readFile(outPath, "utf8");
    } catch {
      mdBody = text;
    }
    const title =
      sanitizeBookDisplayTitle(hint?.title || "") ||
      titleFromMarkdown(mdBody) ||
      titleFromHtml(sliceHtml) ||
      `第 ${chapterIndex + 1} 章`;
    chapterFiles.push({
      index: chapterIndex,
      file: fname,
      title,
      level: hint?.level ?? 0,
      href: fragment ? `${sourceHref}#${fragment}` : sourceHref,
      chars: mdBody.length,
    });
    chapterIndex += 1;
  }

  for (const href of parsed.spine) {
    const abs = resolvePath(extractedDir, href);
    if (!abs || !abs.startsWith(extractedDir)) continue;
    try {
      const html = await readFile(abs, "utf8");
      const fileHints = navToc.filter((item) => sameSpineFile(item.href || "", href));
      const fragments = [...new Set(fileHints.map((item) => item.fragment).filter(Boolean))];
      const slices =
        fragments.length >= 1 ? splitHtmlByAnchorIds(html, fragments) : [{ id: "", html }];
      if (slices.length <= 1) {
        const navMeta = navTitleByIndex.get(chapterIndex) || fileHints[0];
        await writeChapterSlice({
          sliceHtml: html,
          sourceHref: href,
          fragment: "",
          hint: navMeta,
          htmlPath: abs,
        });
        continue;
      }
      for (const slice of slices) {
        const hint = slice.id
          ? fileHints.find((item) => item.fragment === slice.id)
          : fileHints.find((item) => !item.fragment);
        await writeChapterSlice({
          sliceHtml: slice.html,
          sourceHref: href,
          fragment: slice.id,
          hint,
        });
      }
    } catch {
      // skip chapter
    }
  }
  const plain = chunks.join("\n\n").slice(0, bookTextMaxChars());
  await writeFile(textPath, plain, "utf8");

  const indexLines = [
    `# ${parsed.title || book.title || book.id}`,
    parsed.author ? `\n作者：${parsed.author}\n` : "",
    "",
    "问书工作区：请先读本文件，再按需打开 `chapters/` 下的章节 Markdown。",
    "",
    "## 目录",
    ...chapterFiles.map(
      (c, i) => `${i + 1}. [${c.title}](chapters/${c.file}) — ${c.chars} 字`,
    ),
  ].filter((line) => line !== "");
  await writeFile(indexPath, indexLines.join("\n"), "utf8");

  const reading = {
    id: book.id,
    title: parsed.title || book.title,
    author: parsed.author || book.author,
    converter: pandocPath ? "pandoc" : "plain",
    chapters: chapterFiles.map((c) => ({
      index: c.index,
      file: c.file,
      title: c.title,
      level: c.level,
      href: c.href,
    })),
    toc: chapterFiles.map((c) => ({ index: c.index, title: c.title, level: c.level ?? 0 })),
  };
  await writeFile(readingPath, JSON.stringify(reading, null, 2), "utf8");

  if (parsed.coverBuffer?.length) {
    const ext = parsed.coverExt || ".jpg";
    await writeFile(`${coverPath}${ext}`, parsed.coverBuffer);
  }

  await writeFile(
    metaPath,
    JSON.stringify(
      {
        id: book.id,
        title: parsed.title,
        author: parsed.author,
        language: parsed.language,
        sourceMtime: srcMtime,
        sourcePath: book.path,
        spine: parsed.spine,
        materializeVersion: MATERIALIZE_VERSION,
      },
      null,
      2,
    ),
    "utf8",
  );

  return {
    cacheDir,
    extractedDir,
    textPath,
    coverPath,
    chaptersDir,
    indexPath,
    readingPath,
    fresh: true,
  };
}

export function safeChapterFilename(name) {
  const base = path.basename(String(name || "").trim());
  if (!base || base === "." || base === "..") {
    const err = new Error("Invalid chapter file");
    err.status = 400;
    throw err;
  }
  if (!/^\d{3}-[\w\u4e00-\u9fff-]+\.md$/i.test(base)) {
    const err = new Error("Invalid chapter file");
    err.status = 400;
    throw err;
  }
  return base;
}

function sanitizeManifestTitles(items) {
  if (!Array.isArray(items)) return items;
  for (const item of items) {
    if (item && typeof item.title === "string") {
      item.title = sanitizeBookDisplayTitle(item.title) || item.title;
    }
  }
  return items;
}

export async function loadBookReadingManifest(materialized) {
  const readingPath = materialized.readingPath || path.join(materialized.cacheDir, "reading.json");
  const raw = await readFile(readingPath, "utf8");
  const manifest = JSON.parse(raw);
  sanitizeManifestTitles(manifest.chapters);
  sanitizeManifestTitles(manifest.toc);
  return manifest;
}

export function safeBookCacheAssetRelativePath(relPath) {
  const raw = decodeURIComponent(String(relPath || "").trim()).replace(/\\/g, "/");
  if (!raw || raw.includes("\0")) {
    const err = new Error("Invalid asset path");
    err.status = 400;
    throw err;
  }
  if (/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw)) {
    const err = new Error("Invalid asset path");
    err.status = 400;
    throw err;
  }
  const parts = raw.split("/").filter((part) => part.length > 0);
  if (parts.some((part) => part === "..")) {
    const err = new Error("Invalid asset path");
    err.status = 400;
    throw err;
  }
  const normalized = path.posix.normalize(raw);
  if (normalized.startsWith("..") || normalized.includes("/../")) {
    const err = new Error("Invalid asset path");
    err.status = 400;
    throw err;
  }
  return normalized.replace(/^\//, "");
}

const BOOK_ASSET_EXT = /\.(png|jpe?g|gif|webp|svg)$/i;

function walkNamedFiles(dir, out, depth = 0) {
  if (depth > 8 || !existsSync(dir)) return;
  let entries = [];
  try {
    entries = readdirSyncSafe(dir);
  } catch {
    return;
  }
  for (const name of entries) {
    const abs = path.join(dir, name);
    let statInfo;
    try {
      statInfo = statSyncSafe(abs);
    } catch {
      continue;
    }
    if (statInfo?.isDirectory()) walkNamedFiles(abs, out, depth + 1);
    else if (statInfo && BOOK_ASSET_EXT.test(name)) {
      const key = name.toLowerCase();
      if (!out.has(key)) out.set(key, abs);
    }
  }
}

function readdirSyncSafe(dir) {
  return readdirSync(dir);
}

function statSyncSafe(abs) {
  return statSync(abs);
}

const assetIndexByCache = new Map();

export function findBookAssetByName(cacheDir, filename) {
  const base = path.posix.basename(String(filename || "").split("?")[0]);
  if (!base || !BOOK_ASSET_EXT.test(base)) return "";
  const root = path.normalize(String(cacheDir || ""));
  if (!root) return "";
  let index = assetIndexByCache.get(root);
  if (!index) {
    index = new Map();
    walkNamedFiles(path.join(root, "extracted"), index);
    walkNamedFiles(path.join(root, "media"), index);
    walkNamedFiles(path.join(root, "chapters"), index);
    assetIndexByCache.set(root, index);
  }
  return index.get(base.toLowerCase()) || "";
}

export function clearBookAssetIndex(cacheDir) {
  if (cacheDir) assetIndexByCache.delete(path.normalize(cacheDir));
  else assetIndexByCache.clear();
}

export function resolveBookCacheAssetPath(materialized, relativePath) {
  const cacheDir = path.normalize(String(materialized.cacheDir || ""));
  if (!cacheDir) {
    const err = new Error("Book cache missing");
    err.status = 500;
    throw err;
  }
  const raw = decodeURIComponent(String(relativePath || "").trim()).replace(/\\/g, "/");
  try {
    const rel = safeBookCacheAssetRelativePath(raw);
    const abs = path.normalize(path.join(cacheDir, ...rel.split("/")));
    if (abs.startsWith(cacheDir) && existsSync(abs)) return abs;
  } catch {
    // Fall through to filename search — EPUB markdown often uses ../Images/foo.jpeg
  }
  const found = findBookAssetByName(cacheDir, raw);
  if (found && found.startsWith(cacheDir)) return found;
  const err = new Error("Asset not found");
  err.status = 404;
  throw err;
}

export function contentTypeForBookAsset(filePath) {
  const ext = path.extname(String(filePath || "")).toLowerCase();
  switch (ext) {
    case ".png":
      return "image/png";
    case ".jpg":
    case ".jpeg":
      return "image/jpeg";
    case ".gif":
      return "image/gif";
    case ".webp":
      return "image/webp";
    case ".svg":
      return "image/svg+xml";
    default:
      return "application/octet-stream";
  }
}

const MD_IMAGE = /!\[([^\]]*)\]\((<)?([^)\s>]+)(?:>)?(?:\s+(?:"[^"]*"|'[^']*'))?\)/g;
const HTML_IMG = /<img\b[^>]*>/gi;

function htmlImgAttr(tag, name) {
  const match = String(tag || "").match(
    new RegExp(`\\b${name}\\s*=\\s*(["'])([\\s\\S]*?)\\1|\\b${name}\\s*=\\s*([^\\s>]+)`, "i"),
  );
  if (!match) return "";
  return String(match[2] ?? match[3] ?? "").trim();
}

function cleanImageAlt(alt) {
  const text = String(alt || "").trim();
  if (!text || text === "{%}" || /^\{.+\}$/.test(text)) return "";
  return text;
}

function resolvedBookImageRel(materialized, src) {
  const cacheDir = materialized?.cacheDir;
  const raw = String(src || "").trim();
  if (!cacheDir || !raw || /^https?:/i.test(raw) || raw.startsWith("data:")) return "";
  try {
    const abs = resolveBookCacheAssetPath(materialized, raw);
    const rel = path.relative(cacheDir, abs).replace(/\\/g, "/");
    if (!rel || rel.startsWith("..")) return "";
    return rel;
  } catch {
    return "";
  }
}

export function rewriteBookMarkdownImages(markdown, materialized) {
  const cacheDir = materialized?.cacheDir;
  if (!cacheDir) return String(markdown || "");
  const rewritten = String(markdown || "").replace(MD_IMAGE, (full, alt, _lt, src) => {
    const rel = resolvedBookImageRel(materialized, src);
    return rel ? `![${cleanImageAlt(alt)}](${rel})` : full;
  });
  return rewritten.replace(HTML_IMG, (full) => {
    const rel = resolvedBookImageRel(materialized, htmlImgAttr(full, "src"));
    if (!rel) return full;
    return `![${cleanImageAlt(htmlImgAttr(full, "alt"))}](${rel})`;
  });
}

const HTML_A = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;

function decodeHtmlEntities(raw) {
  return String(raw || "")
    .replace(/&nbsp;/g, " ")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

export function rewriteBookMarkdownLinks(markdown) {
  return String(markdown || "").replace(HTML_A, (full, attrs, inner) => {
    const href = decodeHtmlEntities(htmlImgAttr(`<a ${attrs}>`, "href"));
    const text = decodeHtmlEntities(String(inner || "").replace(/<[^>]+>/g, "")).trim();
    if (!href) return text || full;
    return `[${text || href}](${href})`;
  });
}

const HTML_FOOTNOTE =
  /<sup>\s*<a\b[^>]*>\s*<span\b[^>]*>([\s\S]*?)<\/span>\s*<\/a>\s*<\/sup>/gi;
const IMAGE_PLACEHOLDER =
  /<span\b[^>]*(?:data-)?original-image-src\s*=\s*(["'])([^"']+)\1[^>]*>([\s\S]*?)<\/span>/gi;
const CHROME_TAG =
  /<\/?(?:div|span|p|section|article|header|footer|figure|figcaption|nav|main|aside|font|center|sup|sub|u|small)(?:\s[^>]*)?>/gi;

export function sanitizeBookDisplayTitle(title) {
  let out = rewriteBookHtmlChrome(String(title || ""));
  out = out.replace(/<[^>]+>/g, " ");
  out = out.replace(/\*\*|__/g, "").replace(/`+/g, "");
  return out.replace(/\s+/g, " ").trim().slice(0, 160);
}

export function rewriteBookHtmlChrome(markdown) {
  let out = String(markdown || "").replace(HTML_FOOTNOTE, (_, inner) => {
    const note = decodeHtmlEntities(String(inner || "").replace(/<[^>]+>/g, "")).trim();
    return note ? `（${note}）` : "";
  });
  out = out.replace(IMAGE_PLACEHOLDER, (_, _q, src, inner) => {
    const path = String(src || "").trim();
    const alt = decodeHtmlEntities(String(inner || "").replace(/<[^>]+>/g, "")).trim();
    if (!path) return alt;
    return `![${alt === "Cover Image" ? "" : alt}](${path})`;
  });
  out = out.replace(/<br\s*\/?>/gi, "\n");
  out = out.replace(CHROME_TAG, "");
  return decodeHtmlEntities(out).replace(/\n{3,}/g, "\n\n");
}

export async function readBookChapterMarkdown(materialized, filename) {
  const safe = safeChapterFilename(filename);
  const chaptersDir = materialized.chaptersDir || path.join(materialized.cacheDir, "chapters");
  const filePath = path.join(chaptersDir, safe);
  if (!filePath.startsWith(path.normalize(chaptersDir))) {
    const err = new Error("Invalid chapter path");
    err.status = 400;
    throw err;
  }
  const raw = await readFile(filePath, "utf8");
  return rewriteBookMarkdownLinks(
    rewriteBookMarkdownImages(rewriteBookHtmlChrome(raw), materialized),
  );
}

export async function readCachedCover(cacheDir) {
  for (const ext of [".jpg", ".jpeg", ".png", ".gif", ".webp"]) {
    const p = path.join(cacheDir, `cover${ext}`);
    if (existsSync(p)) {
      return { path: p, ext };
    }
  }
  return null;
}

export async function readBookFullText(materialized, { maxChars = bookTextMaxChars() } = {}) {
  try {
    const raw = await readFile(materialized.textPath, "utf8");
    const limit = Number.isFinite(maxChars) && maxChars > 0 ? maxChars : raw.length;
    return raw.slice(0, limit);
  } catch {
    return "";
  }
}

export async function formatBookAcpContext(book, materialized) {
  const lines = [
    `Book title: ${book.title}`,
    `Book id: ${book.id}`,
    `EPUB file: ${book.path}`,
    `Book workspace (ACP cwd): ${materialized.cacheDir}`,
    `Table of contents: ${materialized.indexPath || path.join(materialized.cacheDir, "INDEX.md")}`,
    `Chapter markdown: ${materialized.chaptersDir || path.join(materialized.cacheDir, "chapters")}/`,
    `Plain-text cache (fallback): ${materialized.textPath}`,
  ];
  if (book.author) lines.push(`Author: ${book.author}`);
  try {
    const indexPath = materialized.indexPath || path.join(materialized.cacheDir, "INDEX.md");
    const index = (await readFile(indexPath, "utf8")).slice(0, 6000);
    if (index) {
      lines.push("", "=== INDEX.md (read this first) ===", index);
    }
  } catch {
    // no index
  }
  lines.push(
    "",
    "Workflow: read INDEX.md, then open only the chapter files you need under chapters/.",
    "Prefer chapters/*.md over raw HTML in extracted/. Do not edit files.",
    "Do not invent passages that are not in the book files.",
  );
  return lines.join("\n");
}

export function emptyBookProgress(book) {
  return {
    repo: {
      fullName: book.title || book.id,
      defaultBranch: "book",
      pushedAt: book.modifiedAt || "",
    },
    commits: [],
    pulls: [],
    issues: [],
  };
}

export function bookLocalView(materialized, book) {
  const files = ["INDEX.md", "chapters/", "text.txt"];
  if (materialized.extractedDir) files.push("extracted/");
  return {
    present: true,
    path: materialized.cacheDir,
    branch: "book",
    head: createHash("sha1").update(book.id).digest("hex").slice(0, 7),
    log: "",
    status: "",
    files,
    readme: "",
  };
}

export function bookSessionOwner() {
  return BOOK_OWNER;
}

export function openBookFileStream(bookPath) {
  return createReadStream(bookPath);
}
