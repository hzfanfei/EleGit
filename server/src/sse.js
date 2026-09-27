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
  res.socket?.setTimeout?.(0);
  res.flushHeaders?.();
  res.write(PAD);
  flushSse(res);
  startSseHeartbeat(res);
}

/** Comment frames so a quiet thinking stretch does not look like a dead socket. */
export function startSseHeartbeat(res, intervalMs = 5000) {
  if (!res || typeof res.write !== "function") return () => {};
  const timer = setInterval(() => {
    if (res.writableEnded || res.destroyed || res.socket?.destroyed) {
      clearInterval(timer);
      return;
    }
    try {
      res.write(": ping\n\n");
      flushSse(res);
    } catch {
      clearInterval(timer);
    }
  }, intervalMs);
  timer.unref?.();
  const stop = () => clearInterval(timer);
  if (typeof res.on === "function") {
    res.on("close", stop);
    res.on("finish", stop);
  }
  return stop;
}

export function writeSse(res, event) {
  res.write(`data: ${JSON.stringify(event)}\n\n`);
  flushSse(res);
}

/** The phone socket is already gone, even if the close listener has not run. */
export function sseClientGone(res) {
  if (!res || res.destroyed) return Boolean(res?.destroyed);
  const socket = res.socket;
  if (socket && (socket.destroyed || socket.writable === false)) return true;
  return false;
}

/** Keep draining a finished turn after the phone has already left. */
export function writeSseSafe(res, event) {
  if (!res || res.writableEnded || res.destroyed || res.socket?.destroyed) return;
  try {
    writeSse(res, event);
  } catch {
    /* client disconnected */
  }
}
