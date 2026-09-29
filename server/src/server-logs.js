import { appendFile, mkdir, readFile, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { clientLogFile, redactSecrets } from "./client-logs.js";

const MAX_FILE_BYTES = 1_500_000;
const KEEP_BYTES = 800_000;

let workspaceRoot = "";
let tail = Promise.resolve();
let seq = 0;

export function configureServerLogs(root) {
  workspaceRoot = String(root || "").trim();
}

export function serverLogFile(root) {
  return path.join(String(root || ""), "server-logs", "server-errors.jsonl");
}

function clip(value, max) {
  const text = String(value ?? "").replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g, "");
  return text.length > max ? text.slice(0, max) : text;
}

export function noteServerLog({ message, kind = "error", summary = "", stack = "" }) {
  const root = workspaceRoot;
  if (!root) return;
  const cleaned = redactSecrets(String(message || "")).trim();
  if (!cleaned || cleaned === "cancelled") return;
  seq += 1;
  const entry = {
    id: `srv-${Date.now()}-${seq}`,
    at: new Date().toISOString(),
    kind: clip(kind, 40) || "error",
    message: clip(cleaned, 2000),
    summary: clip(redactSecrets(summary).trim(), 500),
    stack: clip(redactSecrets(stack), 4000),
    origin: "server",
  };
  tail = tail
    .then(() => appendEntry(root, entry))
    .catch(() => {});
}

async function appendEntry(root, entry) {
  const file = serverLogFile(root);
  await mkdir(path.dirname(file), { recursive: true });
  await appendFile(file, `${JSON.stringify(entry)}\n`, "utf8");
  await trimFile(file, MAX_FILE_BYTES, KEEP_BYTES);
}

async function trimFile(file, maxBytes, keepBytes) {
  let info;
  try {
    info = await stat(file);
  } catch {
    return;
  }
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

function normalizeRow(raw, defaultOrigin) {
  if (!raw || typeof raw !== "object") return null;
  const message = redactSecrets(clip(raw.message, 2000)).trim();
  if (!message) return null;
  return {
    id: clip(raw.id, 80).trim() || `row-${message.slice(0, 24)}`,
    at: clip(raw.at || raw.receivedAt, 40).trim() || new Date(0).toISOString(),
    kind: clip(raw.kind, 40).trim() || "error",
    message,
    summary: redactSecrets(clip(raw.summary, 500)).trim(),
    stack: redactSecrets(clip(raw.stack, 4000)),
    origin: clip(raw.origin, 20).trim() || defaultOrigin,
    platform: clip(raw.platform, 40).trim(),
    app: clip(raw.app, 40).trim(),
  };
}

async function readJsonl(file, defaultOrigin, out) {
  let text = "";
  try {
    text = await readFile(file, "utf8");
  } catch {
    return;
  }
  for (const line of text.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    try {
      const row = normalizeRow(JSON.parse(trimmed), defaultOrigin);
      if (row) out.push(row);
    } catch {
      /* skip bad line */
    }
  }
}

export async function listErrorLogs(root, { limit = 200 } = {}) {
  const cap = Math.min(Math.max(Number(limit) || 200, 1), 500);
  const rows = [];
  const base = String(root || "").trim();
  if (!base) return [];
  await readJsonl(serverLogFile(base), "server", rows);
  await readJsonl(clientLogFile(base), "client", rows);
  rows.sort((a, b) => String(b.at).localeCompare(String(a.at)));
  return rows.slice(0, cap);
}

export async function clearErrorLogs(root) {
  const base = String(root || "").trim();
  if (!base) return;
  for (const file of [serverLogFile(base), clientLogFile(base)]) {
    try {
      await mkdir(path.dirname(file), { recursive: true });
      await writeFile(file, "", "utf8");
    } catch {
      /* best effort */
    }
  }
}
