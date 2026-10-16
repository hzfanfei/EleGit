import { randomBytes } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { defaultHomeDir } from "./store.js";

export const CHAT_IMAGE_MIMES = new Map([
  ["image/jpeg", "jpg"],
  ["image/png", "png"],
  ["image/webp", "webp"],
  ["image/gif", "gif"],
]);

export const MAX_CHAT_IMAGES_PER_MESSAGE = 4;
export const MAX_PROMPT_IMAGES = 8;
export const MAX_CHAT_IMAGE_BYTES = 4 * 1024 * 1024;

const ID_RE = /^[a-f0-9]{32}$/;

export function chatImagesDir(root) {
  return path.join(root || defaultHomeDir(), "chat-images");
}

export function normalizeChatImageMime(mime) {
  const raw = String(mime || "").split(";")[0].trim().toLowerCase();
  if (raw === "image/jpg" || raw === "image/pjpeg") return "image/jpeg";
  return CHAT_IMAGE_MIMES.has(raw) ? raw : "";
}

function imageError(message, status) {
  const err = new Error(message);
  err.status = status;
  return err;
}

export function sanitizeImageRefs(raw, limit = MAX_CHAT_IMAGES_PER_MESSAGE) {
  if (!Array.isArray(raw)) return [];
  const out = [];
  const seen = new Set();
  for (const item of raw) {
    const id = String(item?.id || "").trim().toLowerCase();
    if (!ID_RE.test(id) || seen.has(id)) continue;
    seen.add(id);
    out.push({ id });
    if (out.length >= limit) break;
  }
  return out;
}

/** Images the agent should see: this turn only once the session is warm, otherwise recent history too. */
export function promptImageRefs({ history, images, primed, limit = MAX_PROMPT_IMAGES } = {}) {
  const current = sanitizeImageRefs(images);
  if (primed) return current;
  const ordered = [];
  const seen = new Set();
  const push = (refs) => {
    for (const ref of refs) {
      if (seen.has(ref.id)) continue;
      seen.add(ref.id);
      ordered.push(ref);
    }
  };
  for (const message of Array.isArray(history) ? history : []) {
    if (message?.role !== "user") continue;
    push(sanitizeImageRefs(message.images));
  }
  push(current);
  if (ordered.length <= limit) return ordered;
  return ordered.slice(ordered.length - limit);
}

export async function saveChatImage(bytes, mime, dir) {
  const mimeType = normalizeChatImageMime(mime);
  if (!mimeType) throw imageError("只支持 JPEG、PNG、WebP、GIF", 400);
  if (!Buffer.isBuffer(bytes) || bytes.length === 0) throw imageError("缺少图片内容", 400);
  if (bytes.length > MAX_CHAT_IMAGE_BYTES) throw imageError("图片太大", 413);
  const folder = dir || chatImagesDir();
  await mkdir(folder, { recursive: true });
  const id = randomBytes(16).toString("hex");
  const ext = CHAT_IMAGE_MIMES.get(mimeType);
  const filePath = path.join(folder, `${id}.${ext}`);
  await writeFile(filePath, bytes);
  return { id, mimeType };
}

export async function readChatImage(id, dir) {
  const clean = String(id || "").trim().toLowerCase();
  if (!ID_RE.test(clean)) return null;
  const folder = dir || chatImagesDir();
  for (const [mimeType, ext] of CHAT_IMAGE_MIMES) {
    const filePath = path.join(folder, `${clean}.${ext}`);
    try {
      const bytes = await readFile(filePath);
      return { id: clean, mimeType, bytes, path: filePath };
    } catch {
      // Try the next extension.
    }
  }
  return null;
}

export async function loadChatImages(refs, dir) {
  const loaded = [];
  for (const ref of Array.isArray(refs) ? refs : []) {
    const image = await readChatImage(ref?.id, dir);
    if (!image) continue;
    loaded.push({
      id: image.id,
      mimeType: image.mimeType,
      data: image.bytes.toString("base64"),
      path: image.path,
    });
  }
  return loaded;
}
