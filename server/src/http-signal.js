export function isCancelled(err) {
  return err?.code === "cancelled" || err?.message === "cancelled" || err?.message === "已取消";
}

/**
 * Abort only when the client drops the connection, not when Express
 * finishes reading a JSON body (IncomingMessage "close" fires then).
 */
export function requestSignal(req, res) {
  const ac = new AbortController();
  const abort = () => {
    if (!ac.signal.aborted) ac.abort();
  };
  req.on("aborted", abort);
  res.on("close", () => {
    if (!res.writableEnded) abort();
  });
  return ac.signal;
}
