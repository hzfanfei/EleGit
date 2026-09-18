import { createHash } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { mkdir, readdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import AdmZip from "adm-zip";
import { defaultWorkspaceRoot } from "./workspace.js";

const BOOK_OWNER = "_book";

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

  const spine = [];
  const spineBlock = opf.match(/<spine[^>]*>([\s\S]*?)<\/spine>/i)?.[1] || "";
  for (const match of spineBlock.matchAll(/<itemref[^>]+idref=["']([^"']+)["']/gi)) {
    const idref = match[1];
    const itemRe = new RegExp(`<item[^>]+id=["']${idref}["'][^>]+href=["']([^"']+)["']`, "i");
    const hrefMatch = opf.match(itemRe);
    if (hrefMatch?.[1]) {
      spine.push(path.posix.join(opfDir, hrefMatch[1]).replace(/\\/g, "/"));
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
  try {
    const metaRaw = await readFile(metaPath, "utf8");
    const meta = JSON.parse(metaRaw);
    cachedMtime = Number(meta.sourceMtime) || 0;
  } catch {
    cachedMtime = 0;
  }

  if (cachedMtime === srcMtime && existsSync(textPath)) {
    return { cacheDir, extractedDir, textPath, coverPath, fresh: false };
  }

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

  const chunks = [];
  for (const href of parsed.spine) {
    const abs = resolvePath(extractedDir, href);
    if (!abs || !abs.startsWith(extractedDir)) continue;
    try {
      const html = await readFile(abs, "utf8");
      const text = stripHtml(html);
      if (text) chunks.push(text);
    } catch {
      // skip chapter
    }
  }
  const plain = chunks.join("\n\n").slice(0, 500_000);
  await writeFile(textPath, plain, "utf8");

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
      },
      null,
      2,
    ),
    "utf8",
  );

  return { cacheDir, extractedDir, textPath, coverPath, fresh: true };
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

export async function formatBookAcpContext(book, materialized) {
  const lines = [
    `Book title: ${book.title}`,
    `Book id: ${book.id}`,
    `EPUB file: ${book.path}`,
    `Unpacked EPUB directory: ${materialized.extractedDir}`,
    `Plain-text cache: ${materialized.textPath}`,
  ];
  if (book.author) lines.push(`Author: ${book.author}`);
  try {
    const excerpt = (await readFile(materialized.textPath, "utf8")).slice(0, 4000);
    if (excerpt) {
      lines.push("", "Text excerpt (full text is in the cache file):", excerpt);
    }
  } catch {
    // no excerpt
  }
  lines.push(
    "",
    "When answering, read the unpacked HTML/XHTML under the extracted directory and the text cache.",
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
  const files = [];
  if (materialized.extractedDir) {
    files.push("extracted/");
    files.push("text.txt");
  }
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
