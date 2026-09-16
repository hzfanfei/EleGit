const PAD = `:${" ".repeat(2048)}\n\n`;

export function flushSse(res) {
  if (typeof res.flush === "function") res.flush();
}

export function openSse(res) {
  res.status(200);
  res.setHeader("Content-Type", "text/event-stream; charset=utf-8");
  res.setHeader("Cache-Control", "no-cache, no-transform");
  res.setHeader("Connection", "keep-alive");
  res.setHeader("X-Accel-Buffering", "no");
  res.setHeader("Content-Encoding", "identity");
  res.socket?.setNoDelay?.(true);
  res.flushHeaders?.();
  res.write(PAD);
  flushSse(res);
}

export function writeSse(res, event) {
  res.write(`data: ${JSON.stringify(event)}\n\n`);
  flushSse(res);
}
