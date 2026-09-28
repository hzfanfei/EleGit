export const COMPANION_ALREADY_RUNNING = 75;

/** Node CLI args to run the companion (optional --watch when WENXIANG_DEV_WATCH=1). */
export function companionNodeArgs(env = process.env) {
  const script = "src/server.js";
  const watch = String(env.WENXIANG_DEV_WATCH || "").trim().toLowerCase();
  if (watch === "1" || watch === "true" || watch === "yes") {
    return ["--watch", script];
  }
  return [script];
}

export function isCompanionAlreadyRunning(code) {
  return code === COMPANION_ALREADY_RUNNING;
}

export function shouldRestartCompanion(code, signal) {
  if (isCompanionAlreadyRunning(code)) return false;
  if (signal) return true;
  return code !== 0 && code != null;
}

export async function companionIsHealthy(url, { fetchImpl = fetch, timeoutMs = 2000 } = {}) {
  try {
    const res = await fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs) });
    if (!res?.ok) return false;
    const body = typeof res.json === "function" ? await res.json() : null;
    return body?.ok === true && body?.service === "wenxiang";
  } catch {
    return false;
  }
}

export function nextKeepAliveDelay(attempt, baseMs = 2000) {
  const n = Math.max(0, Number(attempt) || 0);
  return Math.min(30_000, baseMs * 2 ** Math.min(n, 4));
}

export function shouldRestartStaleTunnel({
  localHealthy,
  publicHealthy,
  failStreak,
  threshold = 3,
  networkUp = true,
} = {}) {
  if (!localHealthy || publicHealthy) return false;
  if (!networkUp) return false;
  return Number(failStreak) >= Number(threshold);
}

export async function networkLikelyUp({
  fetchImpl = fetch,
  timeoutMs = 4000,
  probeUrl = "https://connectivitycheck.gstatic.com/generate_204",
} = {}) {
  try {
    const res = await fetchImpl(probeUrl, {
      method: "GET",
      signal: AbortSignal.timeout(timeoutMs),
    });
    return res?.ok || res?.status === 204;
  } catch {
    return false;
  }
}
