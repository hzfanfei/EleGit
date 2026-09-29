import { createWriteStream } from "node:fs";
import { access, mkdir, open, rename, unlink } from "node:fs/promises";
import path from "node:path";
import { lookup } from "node:dns/promises";
import { isIP } from "node:net";
import { bookIdFromFilename, booksDir } from "./books.js";

const DEFAULT_LIMIT = 10;
const DEFAULT_TIMEOUT_MS = 8000;
const MAX_DOWNLOAD_BYTES = 200 * 1024 * 1024; // 200 MB
const EBOOK_FORMAT = "epub";

function ensureSignal(signal) {
  if (signal) return signal;
  return AbortSignal.timeout(DEFAULT_TIMEOUT_MS);
}

function decodeEntities(text) {
  return String(text || "")
    .replace(/&nbsp;/g, " ")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function isPrivateIp(ip) {
  if (!ip) return true;
  if (isIP(ip) === 4) {
    const p = ip.split(".").map(Number);
    if (p[0] === 10 || p[0] === 127 || p[0] === 0) return true;
    if (p[0] === 169 && p[1] === 254) return true;
    if (p[0] === 172 && p[1] >= 16 && p[1] <= 31) return true;
    if (p[0] === 192 && p[1] === 168) return true;
    if (p[0] === 100 && p[1] >= 64 && p[1] <= 127) return true; // CGNAT
    if (p[0] >= 224) return true;
    return false;
  }
  if (isIP(ip) === 6) {
    const lc = ip.toLowerCase();
    if (lc === "::1" || lc.startsWith("fc") || lc.startsWith("fd") || lc.startsWith("fe80")) {
      return true;
    }
    return false;
  }
  return true;
}

export async function assertSafeExternalUrl(rawUrl) {
  let parsed;
  try {
    parsed = new URL(String(rawUrl || ""));
  } catch {
    const err = new Error("无效的下载链接");
    err.status = 400;
    err.code = "bad_url";
    throw err;
  }
  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    const err = new Error("仅支持 http/https 下载链接");
    err.status = 400;
    err.code = "bad_protocol";
    throw err;
  }
  const host = parsed.hostname;
  if (!host) {
    const err = new Error("缺少主机名");
    err.status = 400;
    err.code = "bad_host";
    throw err;
  }
  let ips;
  if (isIP(host)) {
    ips = [host];
  } else {
    try {
      const records = await lookup(host, { all: true });
      ips = records.map((r) => r.address).filter(Boolean);
    } catch {
      const err = new Error("无法解析主机");
      err.status = 400;
      err.code = "dns_lookup_failed";
      throw err;
    }
  }
  for (const ip of ips) {
    if (isPrivateIp(ip)) {
      const err = new Error("禁止访问内网地址");
      err.status = 400;
      err.code = "private_ip_blocked";
      throw err;
    }
  }
  return parsed;
}

function normalizeAuthorList(arr) {
  if (!Array.isArray(arr)) return "";
  return arr
    .filter((s) => typeof s === "string" && s.trim())
    .map((s) => s.trim())
    .join(", ");
}

function pickIaCandidates(doc, max = 5) {
  const list = Array.isArray(doc?.ia) ? doc.ia : [];
  const out = [];
  for (const item of list) {
    if (typeof item === "string" && item.trim()) {
      out.push(item.trim());
      if (out.length >= max) break;
    }
  }
  return out;
}

async function fetchArchiveMetadata(iaId, fetchImpl, signal) {
  const url = `https://archive.org/metadata/${encodeURIComponent(iaId)}`;
  let res;
  try {
    res = await fetchImpl(url, {
      signal,
      headers: { Accept: "application/json", "User-Agent": "Wenxiang/1.0 (+book-search)" },
    });
  } catch {
    return null;
  }
  if (!res.ok) return null;
  try {
    return await res.json();
  } catch {
    return null;
  }
}

function pickEpubName(metadata) {
  if (!metadata || !Array.isArray(metadata.files)) return "";
  const epubs = [];
  for (const f of metadata.files) {
    const name = String(f?.name || "");
    if (!/\.epub$/i.test(name)) continue;
    const fmt = String(f?.format || "").toLowerCase();
    epubs.push({ name, fmt });
  }
  if (!epubs.length) return "";
  // 优先格式标记为 EPUB 的，其次是任意 epub 文件
  epubs.sort((a, b) => {
    const aIsEpub = a.fmt.includes("epub");
    const bIsEpub = b.fmt.includes("epub");
    if (aIsEpub && !bIsEpub) return -1;
    if (bIsEpub && !aIsEpub) return 1;
    return 0;
  });
  return epubs[0].name;
}

async function resolveArchiveEpub(iaCandidates, fetchImpl, signal) {
  // 并发查多个 IA 标识符的 metadata，挑第一个有 epub 的返回
  if (!iaCandidates.length) return { ia: "", epub: "" };
  const tasks = iaCandidates.map((id) =>
    fetchArchiveMetadata(id, fetchImpl, signal).then((meta) => ({ id, meta })),
  );
  const settled = await Promise.all(tasks);
  for (const { id, meta } of settled) {
    const epub = pickEpubName(meta);
    if (epub) return { ia: id, epub };
  }
  // 全都查不到 — 也返回第一个 IA，至少 detailUrl 还能用
  return { ia: iaCandidates[0], epub: "" };
}

export async function searchOpenLibrary(query, opts = {}) {
  const fetchImpl = opts.fetchImpl || globalThis.fetch;
  const limit = Math.max(1, Math.min(20, opts.limit || DEFAULT_LIMIT));
  const signal = ensureSignal(opts.signal);
  const trimmedQuery = String(query || "").trim();
  if (!trimmedQuery) return [];

  // OpenLibrary 要求至少 3 字符，短查询补一个空格绕过（tokenize 后无影响）
  const finalQuery = trimmedQuery.length < 3 ? `${trimmedQuery} ` : trimmedQuery;

  const url = new URL("https://openlibrary.org/search.json");
  url.searchParams.set("q", finalQuery);
  url.searchParams.set("limit", String(Math.min(20, limit * 2)));
  url.searchParams.set(
    "fields",
    "key,title,author_name,first_publish_year,ia,ebook_access,public_scan_b,edition_count",
  );

  let res;
  try {
    res = await fetchImpl(url, {
      signal,
      headers: { Accept: "application/json", "User-Agent": "Wenxiang/1.0 (+book-search)" },
    });
  } catch (err) {
    const e = new Error(`OpenLibrary 搜索失败: ${err?.message || "network"}`);
    e.status = 502;
    e.code = "openlibrary_network";
    throw e;
  }
  if (!res.ok) {
    const e = new Error(`OpenLibrary 搜索失败 (${res.status})`);
    e.status = 502;
    e.code = "openlibrary_failed";
    throw e;
  }
  const body = await res.json();
  const docs = Array.isArray(body?.docs) ? body.docs : [];

  const out = [];
  for (const doc of docs) {
    const title = String(doc?.title || "").trim();
    if (!title) continue;
    const access = String(doc?.ebook_access || "").toLowerCase();
    // 仅保留可公开下载的（lending library 的 borrowable 不在 V1 范围）
    if (access !== "public") continue;
    const candidates = pickIaCandidates(doc, 5);
    if (!candidates.length) continue;
    const resolved = await resolveArchiveEpub(candidates, fetchImpl, signal);
    if (!resolved.ia || !resolved.epub) continue;
    out.push({
      source: "openlibrary",
      sourceLabel: "Open Library",
      title: title.slice(0, 160),
      author: normalizeAuthorList(doc.author_name).slice(0, 160),
      year: doc.first_publish_year ? String(doc.first_publish_year) : "",
      format: EBOOK_FORMAT,
      size: "",
      downloadUrl: `https://archive.org/download/${encodeURIComponent(resolved.ia)}/${encodeURIComponent(resolved.epub)}`,
      detailUrl: doc.key ? `https://openlibrary.org${doc.key}` : "",
    });
    if (out.length >= limit) break;
  }
  return out;
}

const JIUMO_HOSTS = ["www.jiumodiary.com", "www2.jiumodiary.com", "www5.jiumodiary.com"];
const JIUMO_FORMATS = [
  ["epub", /epub/i],
  ["mobi", /mobi(?!le)/i],
  ["azw", /azw3?/i],
  ["pdf", /pdf/i],
  ["txt", /txt/i],
  ["doc", /doc(?!ument)/i],
];

function detectJiumoFormat(title, des) {
  const text = `${title || ""} ${des || ""}`;
  for (const [name, re] of JIUMO_FORMATS) {
    if (re.test(text)) return name;
  }
  return "other";
}

function isDirectEbookUrl(raw) {
  try {
    const u = new URL(String(raw || ""));
    if (u.protocol !== "http:" && u.protocol !== "https:") return false;
    return /\.(epub|mobi|azw3?)(\?|#|$)/i.test(u.pathname);
  } catch {
    return false;
  }
}

function jiumoCookieHeader(raw) {
  const trimmed = String(raw || "").trim();
  if (!trimmed) return "";
  if (trimmed.includes("=")) return trimmed;
  return `dyh1_wx6_code=${trimmed}`;
}

async function postJiumoForm(host, pathname, body, opts) {
  const fetchImpl = opts.fetchImpl || globalThis.fetch;
  const signal = ensureSignal(opts.signal);
  const url = `https://${host}/${pathname.replace(/^\//, "")}`;
  const headers = {
    "Content-Type": "application/x-www-form-urlencoded",
    "X-Requested-With": "XMLHttpRequest",
    Accept: "application/json, text/plain, */*",
    "User-Agent": "Mozilla/5.0 (compatible; Wenxiang/1.0; +book-search)",
  };
  const cookie = jiumoCookieHeader(opts.jiumoCookie);
  if (cookie) headers.Cookie = cookie;
  let res;
  try {
    res = await fetchImpl(url, { method: "POST", headers, body, signal });
  } catch (err) {
    const e = new Error(`鸠摩搜索请求失败: ${err?.message || "network"}`);
    e.status = 502;
    e.code = "jiumo_network";
    throw e;
  }
  if (!res.ok) {
    const e = new Error(`鸠摩搜索失败 (${res.status})`);
    e.status = 502;
    e.code = "jiumo_failed";
    throw e;
  }
  const text = await res.text();
  if (!text.trim()) return null;
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

function flattenJiumoHubs(hubs) {
  const items = [];
  if (!Array.isArray(hubs)) return items;
  for (const hub of hubs) {
    const details = hub?.details;
    if (!details || details.status !== "succeed") continue;
    const viewType = String(hub?.view_type || "");
    const data = details.data;
    if (viewType === "view_forum" && data && typeof data === "object" && !Array.isArray(data)) {
      for (const group of Object.values(data)) {
        const rows = Array.isArray(group?.data) ? group.data : [];
        for (const row of rows) items.push(row);
      }
      continue;
    }
    const rows = Array.isArray(data) ? data : [];
    for (const row of rows) items.push(row);
  }
  return items;
}

function mapJiumoItem(row) {
  const link = String(row?.link || "").trim();
  const title = decodeEntities(String(row?.title || "").trim());
  if (!link || !title) return null;
  if (!/^https?:\/\//i.test(link)) return null;
  const des = decodeEntities(String(row?.des || row?.info || "").trim());
  const format = detectJiumoFormat(title, des);
  const direct = isDirectEbookUrl(link);
  return {
    source: "jiumo",
    sourceLabel: "鸠摩搜索",
    title: title.slice(0, 160),
    author: des.slice(0, 160),
    year: "",
    format,
    size: "",
    downloadUrl: direct && format === "epub" ? link : "",
    detailUrl: link,
    rateSummary: Number.parseInt(String(row?.rate_summary ?? "0"), 10) || 0,
  };
}

async function fetchJiumoHubs(query, opts) {
  const trimmedQuery = String(query || "").trim();
  const timeInt = Date.now();
  const initBody = `q=${encodeURIComponent(trimmedQuery)}&remote_ip=&time_int=${timeInt}`;
  let initJson = null;
  let usedHost = "";
  for (const host of JIUMO_HOSTS) {
    initJson = await postJiumoForm(host, "init_hubs.php", initBody, { ...opts, host });
    if (initJson?.status === "succeed") {
      usedHost = host;
      break;
    }
    if (initJson?.status === "exceed" || initJson?.status === "tooshort") {
      return { hubs: [], host: "" };
    }
  }
  if (!usedHost || !initJson || initJson.status !== "succeed") {
    return { hubs: [], host: "" };
  }
  let hubs = Array.isArray(initJson.sources) ? [...initJson.sources] : [];
  let count = Number.parseInt(String(initJson.count ?? "0"), 10) || hubs.length;
  const id = initJson.id;
  if (!id) return { hubs, host: usedHost };

  for (let round = 0; round < 12; round += 1) {
    const ajaxBody = `id=${encodeURIComponent(id)}&set=${encodeURIComponent(String(count))}`;
    const ajaxJson = await postJiumoForm(usedHost, "ajax_fetch_hubs.php", ajaxBody, opts);
    if (!ajaxJson || ajaxJson.status !== "succeed") break;
    if (Array.isArray(ajaxJson.sources) && ajaxJson.sources.length) {
      hubs = hubs.concat(ajaxJson.sources);
    }
    count = Number.parseInt(String(ajaxJson.count ?? count), 10) || count;
    if (String(ajaxJson.status_extra || "") === "completed") break;
  }
  return { hubs, host: usedHost };
}

/**
 * 鸠摩搜索 (jiumodiary.com)。站点需微信公众号验证码 Cookie（dyh1_wx6_code），
 * 可通过环境变量 WENXIANG_JIUMO_COOKIE 配置；未配置时静默跳过该源。
 */
export async function searchJiumo(query, opts = {}) {
  const fetchImpl = opts.fetchImpl || globalThis.fetch;
  const limit = Math.max(1, Math.min(20, opts.limit || DEFAULT_LIMIT));
  const signal = ensureSignal(opts.signal);
  const trimmedQuery = String(query || "").trim();
  if (!trimmedQuery) return [];

  const jiumoCookie =
    opts.jiumoCookie ?? process.env.WENXIANG_JIUMO_COOKIE ?? "";
  if (!jiumoCookieHeader(jiumoCookie)) {
    return [];
  }

  const { hubs } = await fetchJiumoHubs(trimmedQuery, {
    fetchImpl,
    signal,
    jiumoCookie,
  });
  const flat = flattenJiumoHubs(hubs);
  const seen = new Set();
  const ranked = [];
  for (const row of flat) {
    const mapped = mapJiumoItem(row);
    if (!mapped) continue;
    if (seen.has(mapped.detailUrl)) continue;
    seen.add(mapped.detailUrl);
    ranked.push(mapped);
  }
  ranked.sort((a, b) => b.rateSummary - a.rateSummary || a.title.localeCompare(b.title, "zh"));
  return ranked.slice(0, limit).map(({ rateSummary: _rs, ...rest }) => rest);
}

export async function searchBooks(query, opts = {}) {
  const sources = Array.isArray(opts.sources) && opts.sources.length
    ? opts.sources
    : ["openlibrary", "jiumo"];
  const limit = Math.max(1, Math.min(20, opts.limit || DEFAULT_LIMIT));
  const signal = ensureSignal(opts.signal);
  const fetchImpl = opts.fetchImpl || globalThis.fetch;

  const tasks = sources.map((source) => {
    if (source === "openlibrary") {
      return searchOpenLibrary(query, { fetchImpl, limit, signal }).catch((err) => ({
        __sourceError: source,
        message: err?.message || String(err),
        code: err?.code,
      }));
    }
    if (source === "jiumo") {
      return searchJiumo(query, { fetchImpl, limit, signal }).catch((err) => ({
        __sourceError: source,
        message: err?.message || String(err),
        code: err?.code,
      }));
    }
    return Promise.resolve({ __sourceError: source, message: "unknown source", code: "bad_source" });
  });

  const settled = await Promise.all(tasks);
  const merged = [];
  for (const r of settled) {
    if (Array.isArray(r)) merged.push(...r);
  }
  return merged;
}

async function findFreeFilename(dir, baseName) {
  // baseName 不含扩展名；扩展名在外层追加
  let candidate = baseName;
  let n = 2;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const candidatePath = path.join(dir, `${candidate}.epub`);
    try {
      await access(candidatePath);
    } catch {
      return `${candidate}.epub`;
    }
    candidate = `${baseName}-${n}`;
    n += 1;
    if (n > 999) return `${baseName}-${Date.now()}.epub`; // 兜底
  }
}

export async function downloadBookFromUrl(rawUrl, opts = {}) {
  const fetchImpl = opts.fetchImpl || globalThis.fetch;
  const signal = ensureSignal(opts.signal);
  const workspaceRoot = opts.workspaceRoot;
  if (!workspaceRoot) {
    const err = new Error("缺少 workspaceRoot");
    err.status = 500;
    err.code = "no_workspace";
    throw err;
  }

  const parsed = await assertSafeExternalUrl(rawUrl);

  let res;
  try {
    res = await fetchImpl(parsed, {
      signal,
      redirect: "follow",
      headers: { "User-Agent": "Wenxiang/1.0 (+book-download)" },
    });
  } catch (err) {
    const e = new Error(`下载请求失败: ${err?.message || "network"}`);
    e.status = 502;
    e.code = "download_network";
    throw e;
  }
  if (!res.ok) {
    const e = new Error(`下载失败 (${res.status})`);
    e.status = res.status === 401 || res.status === 403 ? 415 : 502;
    e.code = "download_failed";
    throw e;
  }
  const contentType = String(res.headers.get("content-type") || "").toLowerCase();
  if (contentType.startsWith("text/html")) {
    const e = new Error("下载到了网页而不是 epub（可能该书需要借阅登录）");
    e.status = 415;
    e.code = "not_epub";
    throw e;
  }
  const lengthHeader = res.headers.get("content-length");
  const declaredLength = lengthHeader ? Number(lengthHeader) : 0;
  if (declaredLength > MAX_DOWNLOAD_BYTES) {
    const e = new Error("文件过大，已超过 200MB 限制");
    e.status = 413;
    e.code = "too_large";
    throw e;
  }

  const dir = booksDir(workspaceRoot);
  await mkdir(dir, { recursive: true });

  // 基础文件名
  const urlBaseName = decodeEntities(
    String(parsed.pathname.split("/").pop() || "downloaded-book"),
  ).replace(/\.epub$/i, "");
  const hint = String(opts.suggestedTitle || "").trim();
  const baseRaw = hint || urlBaseName || "downloaded-book";
  const safeBase = bookIdFromFilename(`${baseRaw}.epub`).replace(/\.epub$/i, "");
  const finalName = await findFreeFilename(dir, safeBase);
  const finalPath = path.join(dir, finalName);
  const tempPath = `${finalPath}.part`;

  const writeStream = createWriteStream(tempPath);
  let totalBytes = 0;
  const cleanup = async () => {
    try {
      writeStream.destroy();
    } catch {
      // ignore
    }
    try {
      await unlink(tempPath);
    } catch {
      // ignore
    }
  };

  try {
    if (!res.body) {
      throw Object.assign(new Error("下载响应没有 body"), {
        status: 502,
        code: "download_no_body",
      });
    }
    for await (const chunk of res.body) {
      totalBytes += chunk.length;
      if (totalBytes > MAX_DOWNLOAD_BYTES) {
        await cleanup();
        const e = new Error("文件过大，已超过 200MB 限制");
        e.status = 413;
        e.code = "too_large";
        throw e;
      }
      if (!writeStream.write(chunk)) {
        await new Promise((resolve) => writeStream.once("drain", resolve));
      }
    }
    await new Promise((resolve, reject) => {
      writeStream.end((err) => (err ? reject(err) : resolve()));
    });
  } catch (err) {
    await cleanup();
    throw err;
  }

  // 校验 zip magic PK\x03\x04
  let handle;
  try {
    handle = await open(tempPath, "r");
    const buf = Buffer.alloc(4);
    const { bytesRead } = await handle.read(buf, 0, 4, 0);
    if (
      bytesRead < 4 ||
      buf[0] !== 0x50 ||
      buf[1] !== 0x4b ||
      buf[2] !== 0x03 ||
      buf[3] !== 0x04
    ) {
      await cleanup();
      const e = new Error("下载内容不是合法的 epub (zip) 文件");
      e.status = 415;
      e.code = "not_epub";
      throw e;
    }
  } catch (err) {
    await cleanup();
    if (err?.status) throw err;
    throw err;
  } finally {
    if (handle) {
      try {
        await handle.close();
      } catch {
        // ignore
      }
    }
  }

  try {
    await rename(tempPath, finalPath);
  } catch (err) {
    await cleanup();
    throw err;
  }

  return {
    filename: finalName,
    path: finalPath,
    size: totalBytes,
    source: "openlibrary",
  };
}