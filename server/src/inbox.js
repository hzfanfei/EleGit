// Per-server inbox of agent notifications (background task completions, etc.).
//
// Lives at <workspaceRoot>/.wenxiang/inbox.json — same single-user server model
// the rest of the companion uses (single X-Wenxiang-Key).

import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { keepEndedScriptRows } from "./script-activity.js";

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
  const stored = { ...item };
  delete stored.alert;
  const partial = item.partial === true;
  return {
    ...stored,
    id,
    createdAt: item.createdAt || new Date().toISOString(),
    // Progress rows are not alerts. A finished answer starts unread so it
    // can be notified once.
    read: partial,
    partial,
  };
}

function turnKey(item) {
  const kind = String(item?.kind || "");
  const turnId = String(item?.turnId || "").trim();
  if (turnId) return `turn\0${kind}\0${turnId}`;
  const sessionId = String(item?.sessionId || "").trim();
  const question = String(item?.question || "");
  if (!sessionId || !question) return "";
  return `q\0${kind}\0${sessionId}\0${question}`;
}

function sameOpenTurn(existing, item) {
  if (existing?.partial !== true || existing.kind !== item?.kind) return false;
  const turnId = String(item?.turnId || "").trim();
  if (turnId) return String(existing.turnId || "") === turnId;
  return Boolean(existing.sessionId)
    && existing.sessionId === item?.sessionId
    && existing.question === item?.question;
}

function findSameTurn(items, item) {
  const key = turnKey(item);
  if (key) return items.findIndex((it) => turnKey(it) === key);
  return items.findIndex((it) => sameOpenTurn(it, item));
}

export async function appendInboxItem(workspaceRoot, item) {
  const items = await readInbox(workspaceRoot);
  const openIndex = findSameTurn(items, item);
  if (openIndex >= 0) {
    const prev = items[openIndex];
    const incomingPartial = item.partial === true;
    const prevDone = prev.partial !== true;
    // A finished turn stays finished. A late progress write must not open
    // a second row or mark the answer unread again.
    if (prevDone && incomingPartial) {
      return { ...prev, alert: false };
    }
    const incoming = incomingPartial && item.activity != null
      ? { ...item, activity: keepEndedScriptRows(prev.activity, item.activity) }
      : item;
    const storedIncoming = { ...incoming };
    delete storedIncoming.alert;
    const alreadyDone = prevDone && !incomingPartial;
    const next = {
      ...prev,
      ...storedIncoming,
      id: prev.id,
      createdAt: alreadyDone ? prev.createdAt : new Date().toISOString(),
      read: incomingPartial ? true : (alreadyDone ? prev.read : false),
      partial: incomingPartial,
    };
    items.splice(openIndex, 1);
    items.unshift(next);
    if (items.length > INBOX_CAP) items.length = INBOX_CAP;
    await writeInbox(workspaceRoot, items);
    return { ...next, alert: !incomingPartial && !alreadyDone };
  }
  const stamped = stampItem(item);
  items.unshift(stamped);
  if (items.length > INBOX_CAP) items.length = INBOX_CAP;
  await writeInbox(workspaceRoot, items);
  return { ...stamped, alert: item.partial !== true };
}

/** Replace one partial row's activity only when it still matches. */
export async function patchInboxActivity(workspaceRoot, id, expectedActivity, activity) {
  const items = await readInbox(workspaceRoot);
  const index = items.findIndex((it) => it.id === id);
  if (index < 0) return null;
  const prev = items[index];
  if (prev.partial !== true || prev.activity !== expectedActivity) return null;
  const next = {
    ...prev,
    activity,
    createdAt: new Date().toISOString(),
    read: prev.partial === true ? true : prev.read,
  };
  items.splice(index, 1);
  items.unshift(next);
  if (items.length > INBOX_CAP) items.length = INBOX_CAP;
  await writeInbox(workspaceRoot, items);
  return next;
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
