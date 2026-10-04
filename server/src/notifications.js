// WebSocket gateway for pushing inbox events to clients.
//
// Path: /v1/notifications. The phone cannot set headers on the upgrade,
// so the key is accepted from the header or the `key` query (same as voice).
// On connect, sends a snapshot of recent unread items, then any new items
// are pushed as `{type:"inbox", item}` messages. Heartbeats every 25s
// to keep intermediate proxies (ngrok etc.) from idling the socket.

import { appendInboxItem, listInbox } from "./inbox.js";
import { WebSocketServer } from "ws";

const HEARTBEAT_MS = 25_000;
const BUFFER_CAP = 50;

let wss = null;
let subscribers = null;
let recentBuffer = [];

export function notificationKeyFromRequest(req) {
  const header = String(req?.headers?.["x-wenxiang-key"] || "").trim();
  if (header) return header;
  try {
    const url = new URL(req?.url || "", "http://127.0.0.1");
    return String(url.searchParams.get("key") || "").trim();
  } catch {
    return "";
  }
}

export function attachNotifications(httpServer, { getStore }) {
  if (wss) return;
  wss = new WebSocketServer({ noServer: true });
  subscribers = new Set();

  httpServer.on("upgrade", (req, socket, head) => {
    if (!req.url || !req.url.startsWith("/v1/notifications")) return;
    const apiKey = notificationKeyFromRequest(req);
    const expected = (() => {
      try {
        return getStore().config.apiKey;
      } catch {
        return "";
      }
    })();
    if (!expected || apiKey !== expected) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }
    wss.handleUpgrade(req, socket, head, (ws) => {
      wss.emit("connection", ws, req);
    });
  });

  wss.on("connection", (ws) => {
    subscribers.add(ws);
    void (async () => {
      let items = recentBuffer;
      try {
        const root = getStore().config.workspaceRoot;
        const unread = await listInbox(root, { unreadOnly: true });
        const ids = new Set(unread.map((it) => it.id));
        items = recentBuffer.filter((it) => it?.id && ids.has(it.id));
      } catch {
        /* snapshot is best-effort */
      }
      if (ws.readyState !== ws.OPEN) return;
      try {
        ws.send(JSON.stringify({ type: "snapshot", items }));
      } catch {}
    })();
    const timer = setInterval(() => {
      if (ws.readyState !== ws.OPEN) return;
      try {
        ws.ping();
      } catch {
        /* client likely gone */
      }
    }, HEARTBEAT_MS);
    const close = () => {
      clearInterval(timer);
      subscribers.delete(ws);
    };
    ws.on("close", close);
    ws.on("error", close);
  });
}

export function broadcastInboxItem(item) {
  if (!subscribers || !item) return false;
  recentBuffer.unshift(item);
  if (recentBuffer.length > BUFFER_CAP) recentBuffer.length = BUFFER_CAP;
  const payload = JSON.stringify({ type: "inbox", item });
  let delivered = false;
  for (const ws of subscribers) {
    if (ws.readyState !== ws.OPEN) continue;
    try {
      ws.send(payload);
      delivered = true;
    } catch {
      /* client likely gone */
    }
  }
  return delivered;
}

/** Progress updates stay on the socket. A finished turn is pushed once. */
export function shouldPushNotice(notice, item) {
  if (!item) return false;
  if (notice?.partial === true) return item.partial === true;
  return item.alert !== false;
}

/** Store a notice. Push progress live, and push a finished answer once per turn. */
export async function publishInboxNotice(workspaceRoot, notice) {
  if (!workspaceRoot || !notice) return null;
  const stored = await appendInboxItem(workspaceRoot, notice);
  if (!stored) return null;
  const { alert, ...item } = stored;
  if (!shouldPushNotice(notice, { ...item, alert })) return item;
  broadcastInboxItem(item);
  return item;
}

export function notificationSubscriberCount() {
  return subscribers ? subscribers.size : 0;
}
