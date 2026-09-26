// Per-server inbox of agent notifications (background task completions, etc.).
//
// Lives at <workspaceRoot>/.wenxiang/inbox.json — same single-user server model
// the rest of the companion uses (single X-Wenxiang-Key).

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";

const INBOX_CAP = 100;

function inboxPath(workspaceRoot) {
  return path.join(workspaceRoot, ".wenxiang", "inbox.json");
}

async function ensureInboxFile(workspaceRoot) {
  const dir = path.join(workspaceRoot, ".wenxiang");
  await mkdir(dir, { recursive: true });
  try {
    await readFile(inboxPath(workspaceRoot), "utf8");
  } catch {
    await writeFile(
      inboxPath(workspaceRoot),
      JSON.stringify({ items: [] }, null, 2),
      "utf8",
    );
  }
}

async function readInbox(workspaceRoot) {
  await ensureInboxFile(workspaceRoot);
  try {
    const text = await readFile(inboxPath(workspaceRoot), "utf8");
    const parsed = JSON.parse(text);
    return Array.isArray(parsed.items) ? parsed.items : [];
  } catch {
    return [];
  }
}

async function writeInbox(workspaceRoot, items) {
  await ensureInboxFile(workspaceRoot);
  await writeFile(
    inboxPath(workspaceRoot),
    JSON.stringify({ items }, null, 2),
    "utf8",
  );
}

function stampItem(item) {
  const id = item.id || `inb_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;
  return {
    ...item,
    id,
    createdAt: item.createdAt || new Date().toISOString(),
    read: false,
  };
}

export async function appendInboxItem(workspaceRoot, item) {
  const items = await readInbox(workspaceRoot);
  const stamped = stampItem(item);
  items.unshift(stamped);
  if (items.length > INBOX_CAP) items.length = INBOX_CAP;
  await writeInbox(workspaceRoot, items);
  return stamped;
}

export async function markInboxRead(workspaceRoot, id) {
  const items = await readInbox(workspaceRoot);
  let changed = false;
  for (const it of items) {
    if (it.id === id && !it.read) {
      it.read = true;
      changed = true;
      break;
    }
  }
  if (changed) await writeInbox(workspaceRoot, items);
  return changed;
}

export async function clearInbox(workspaceRoot) {
  await writeInbox(workspaceRoot, []);
}

export async function listInbox(workspaceRoot, { unreadOnly = false } = {}) {
  const items = await readInbox(workspaceRoot);
  return unreadOnly ? items.filter((it) => !it.read) : items;
}
