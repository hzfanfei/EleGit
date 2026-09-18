export function createTunnelHealth({
  getPublicUrl,
  fetchImpl = fetch,
  intervalMs = 30_000,
} = {}) {
  let reachable = null;
  let error = "";
  let timer = null;

  async function probe() {
    const root = String(getPublicUrl?.() || "").replace(/\/+$/, "");
    if (!root) {
      reachable = null;
      error = "";
      return;
    }
    try {
      const res = await fetchImpl(`${root}/health`, {
        headers: { "ngrok-skip-browser-warning": "true" },
        signal: AbortSignal.timeout(8000),
      });
      reachable = Boolean(res?.ok);
      error = reachable ? "" : `HTTP ${res?.status || 0}`;
    } catch (err) {
      reachable = false;
      error = err?.message || "tunnel probe failed";
    }
  }

  function start() {
    if (timer) return status();
    probe();
    timer = setInterval(() => {
      probe().catch(() => {});
    }, intervalMs);
    if (typeof timer.unref === "function") timer.unref();
    return status();
  }

  function stop() {
    if (timer) clearInterval(timer);
    timer = null;
  }

  function status() {
    return { reachable, error };
  }

  return { probe, start, stop, status };
}
