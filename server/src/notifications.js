// WebSocket gateway for pushing inbox events to clients.
//
// Path: /v1/notifications, authenticates via X-Wenxiang-Key header.
// On connect, sends a snapshot of recent unread items, then any new items
// are pushed as `{type:"inbox", item}` messages. Heartbeats every 25s
// to keep intermediate proxies (ngrok etc.) from idling the socket.

import { WebSocketServer } from "ws";

const HEARTBEAT_MS = 25_000;
const BUFFER_CAP = 50;

let wss = null;
let subscribers = null;
let recentBuffer = [];

export function attachNotifications(httpServer, { getStore }) {
  if (wss) return;
  wss = new WebSocketServer({ noServer: true });
  subscribers = new Set();

  httpServer.on("upgrade", (req, socket, head) => {
    if (!req.url || !req.url.startsWith("/v1/notifications")) return;
    const apiKey = String(req.headers["x-wenxiang-key"] || "");
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
    try {
      ws.send(JSON.stringify({ type: "snapshot", items: recentBuffer }));
    } catch {}
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
  if (!subscribers) return;
  recentBuffer.unshift(item);
  if (recentBuffer.length > BUFFER_CAP) recentBuffer.length = BUFFER_CAP;
  const payload = JSON.stringify({ type: "inbox", item });
  for (const ws of subscribers) {
    if (ws.readyState !== ws.OPEN) continue;
    try {
      ws.send(payload);
    } catch {
      /* client likely gone */
    }
  }
}

export function notificationSubscriberCount() {
  return subscribers ? subscribers.size : 0;
}
