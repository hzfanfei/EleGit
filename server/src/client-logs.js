import { appendFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";

const MAX_FILE_BYTES = 1_500_000;
const KEEP_BYTES = 800_000;
const MAX_BATCH = 40;

let tail = Promise.resolve();

export function clientLogFile(workspaceRoot) {
  return path.join(workspaceRoot, "client-logs", "client-errors.jsonl");
}

function clip(value, max) {
  const text = String(value ?? "").replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, "");
  return text.length > max ? text.slice(0, max) : text;
}

export function redactSecrets(text) {
  return String(text ?? "")
    .replace(/X-Wenxiang-Key\s*[:=]\s*\S+/gi, "X-Wenxiang-Key: [redacted]")
    .replace(/("apiKey"\s*:\s*")[^"]+/gi, '$1[redacted]')
    .replace(/\b(?:ghp_|github_pat_|sk-)[A-Za-z0-9_\-]+/g, "[redacted]")
    .replace(/\bBearer\s+\S+/gi, "Bearer [redacted]");
}

export function sanitizeClientEntry(raw) {
  if (!raw || typeof raw !== "object") return null;
  const message = redactSecrets(clip(raw.message, 2000)).trim();
  if (!message || message === "cancelled") return null;
  return {
    id: clip(raw.id, 80).trim(),
    at: clip(raw.at, 40).trim(),
    kind: clip(raw.kind, 40).trim() || "error",
    message,
    summary: redactSecrets(clip(raw.summary, 500)).trim(),
    stack: redactSecrets(clip(raw.stack, 4000)),
  };
}

export function appendClientLogs(workspaceRoot, entries, meta = {}) {
  const run = tail.then(() => writeBatch(workspaceRoot, entries, meta));
  tail = run.then(
    () => {},
    () => {},
  );
  return run;
}

async function writeBatch(workspaceRoot, entries, meta) {
  const list = Array.isArray(entries) ? entries.slice(0, MAX_BATCH) : [];
  const accepted = [];
  const lines = [];
  const receivedAt = new Date().toISOString();
  const app = clip(meta.app, 40).trim() || "wenxiang";
  const platform = clip(meta.platform, 40).trim();
  for (const raw of list) {
    const id = raw && typeof raw === "object" ? clip(raw.id, 80).trim() : "";
    const clean = sanitizeClientEntry(raw);
    if (!clean) {
      if (id) accepted.push(id);
      continue;
    }
    if (!clean.id) clean.id = `srv-${receivedAt}-${lines.length}`;
    lines.push(
      JSON.stringify({
        receivedAt,
        app,
        platform,
        ...clean,
      }),
    );
    if (id) accepted.push(id);
  }
  if (lines.length > 0) {
    const file = clientLogFile(workspaceRoot);
    await mkdir(path.dirname(file), { recursive: true });
    await appendFile(file, `${lines.join("\n")}\n`, "utf8");
    await trimFile(file, meta.maxBytes || MAX_FILE_BYTES, meta.keepBytes || KEEP_BYTES);
  }
  return accepted;
}

async function trimFile(file, maxBytes, keepBytes) {
  const info = await stat(file);
  if (info.size <= maxBytes) return;
  const text = await readFile(file, "utf8");
  const lines = text.split("\n").filter(Boolean);
  const kept = [];
  let size = 0;
  for (let i = lines.length - 1; i >= 0; i -= 1) {
    const line = lines[i];
    if (kept.length > 0 && size + line.length + 1 > keepBytes) break;
    kept.push(line);
    size += line.length + 1;
  }
  kept.reverse();
  await writeFile(file, kept.length ? `${kept.join("\n")}\n` : "", "utf8");
}
