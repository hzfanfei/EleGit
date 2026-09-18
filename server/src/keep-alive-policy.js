export function shouldRestartCompanion(code, signal) {
  if (signal) return true;
  return code !== 0 && code != null;
}

export function nextKeepAliveDelay(attempt, baseMs = 2000) {
  const n = Math.max(0, Number(attempt) || 0);
  return Math.min(30_000, baseMs * 2 ** Math.min(n, 4));
}
