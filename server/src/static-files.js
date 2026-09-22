import { createReadStream } from "node:fs";
import { mkdir, readdir, stat } from "node:fs/promises";
import path from "node:path";

const SKIP_DIR = new Set(["node_modules"]);
const MAX_FILES = 200;

const CONTENT_TYPES = {
  ".apk": "application/vnd.android.package-archive",
  ".aab": "application/octet-stream",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".svg": "image/svg+xml",
  ".pdf": "application/pdf",
  ".zip": "application/zip",
  ".txt": "text/plain; charset=utf-8",
  ".md": "text/markdown; charset=utf-8",
  ".json": "application/json",
  ".mp4": "video/mp4",
  ".mp3": "audio/mpeg",
  ".wav": "audio/wav",
};

const INLINE_EXT = new Set([
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".webp",
  ".svg",
  ".txt",
  ".md",
  ".pdf",
  ".mp4",
  ".mp3",
  ".wav",
]);

export function staticDir(workspaceRoot) {
  const custom = String(process.env.WENXIANG_STATIC_DIR || "").trim();
  if (custom) return path.resolve(custom);
  return path.join(workspaceRoot, "static");
}

export async function ensureStaticDir(workspaceRoot) {
  const dir = staticDir(workspaceRoot);
  await mkdir(dir, { recursive: true });
  return dir;
}

export function staticDownloadAuthorized({ token, headerKey, staticToken, apiKey } = {}) {
  const provided = String(token || "");
  const header = String(headerKey || "");
  if (staticToken && provided && provided === String(staticToken)) return true;
  if (apiKey && header && header === String(apiKey)) return true;
  return false;
}

export function contentTypeForStatic(filePath) {
  const ext = path.extname(String(filePath || "")).toLowerCase();
  return CONTENT_TYPES[ext] || "application/octet-stream";
}

export function staticContentDisposition(name, filePath) {
  const ext = path.extname(String(filePath || name || "")).toLowerCase();
  const kind = INLINE_EXT.has(ext) ? "inline" : "attachment";
  const base = path.basename(String(name || "download"));
  const ascii = base.replace(/[^\x20-\x7E]/g, "_").replace(/["\\]/g, "_");
  const star = encodeURIComponent(base);
  return `${kind}; filename="${ascii}"; filename*=UTF-8''${star}`;
}

export function staticDownloadUrl(publicUrl, rel, token) {
  const base = String(publicUrl || "").replace(/\/+$/, "");
  const encoded = String(rel || "")
    .split("/")
    .filter(Boolean)
    .map((seg) => encodeURIComponent(seg))
    .join("/");
  const url = `${base}/files/${encoded}`;
  const value = String(token || "").trim();
  if (!value) return url;
  return `${url}?token=${encodeURIComponent(value)}`;
}

export function staticFilesPrompt(config = {}) {
  const dir = staticDir(config.workspaceRoot);
  const token = String(config.staticToken || "").trim();
  const publicUrl = String(config.publicUrl || "").replace(/\/+$/, "");
  return {
    dir,
    linkTemplate:
      publicUrl && token ? `${publicUrl}/files/<path>?token=${token}` : "",
  };
}

function invalidPath(detail) {
  const err = new Error("路径无效");
  err.status = 400;
  err.code = "static_path";
  err.detail = detail;
  return err;
}

export function normalizeStaticRelative(rel) {
  let text = String(rel || "").trim();
  try {
    text = decodeURIComponent(text);
  } catch {
    throw invalidPath(rel);
  }
  text = text.replace(/\\/g, "/").replace(/^\/+/, "");
  const parts = text.split("/");
  if (
    !text ||
    parts.some((seg) => !seg || seg === "." || seg === ".." || seg.includes(":") || seg.startsWith("."))
  ) {
    throw invalidPath(rel);
  }
  return parts.join("/");
}

export function resolveStaticFile(root, rel) {
  const relative = normalizeStaticRelative(rel);
  const base = path.resolve(root);
  const abs = path.resolve(base, relative);
  if (abs !== base && !abs.startsWith(base + path.sep)) {
    throw invalidPath(rel);
  }
  return { relative, abs };
}

export async function listStaticFiles(workspaceRoot, { publicUrl, token } = {}) {
  const root = staticDir(workspaceRoot);
  const files = [];

  async function walk(rel) {
    if (files.length >= MAX_FILES) return;
    const abs = rel ? path.join(root, rel) : root;
    let entries;
    try {
      entries = await readdir(abs, { withFileTypes: true });
    } catch {
      return;
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const entry of entries) {
      if (files.length >= MAX_FILES) return;
      if (entry.name.startsWith(".") || entry.name.includes(":")) continue;
      const next = rel ? `${rel}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        if (SKIP_DIR.has(entry.name)) continue;
        await walk(next);
        continue;
      }
      if (!entry.isFile()) continue;
      const full = path.join(root, next);
      let info;
      try {
        info = await stat(full);
      } catch {
        continue;
      }
      const posix = next.replace(/\\/g, "/");
      files.push({
        path: posix,
        name: entry.name,
        size: info.size,
        mtime: info.mtime.toISOString(),
        contentType: contentTypeForStatic(posix),
        downloadUrl: staticDownloadUrl(publicUrl, posix, token),
      });
    }
  }

  await walk("");
  files.sort((a, b) => String(b.mtime || "").localeCompare(String(a.mtime || "")));
  return { dir: root, files };
}

export function openStaticFileStream(abs) {
  return createReadStream(abs);
}
