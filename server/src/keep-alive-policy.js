export const COMPANION_ALREADY_RUNNING = 75;

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
