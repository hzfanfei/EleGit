export async function readReadyHealth(baseUrl, fetchImpl = fetch, timeoutMs = 1500) {
  try {
    const res = await fetchImpl(`${String(baseUrl || "").replace(/\/$/, "")}/health`, {
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res?.ok) return null;
    const json = await res.json();
    return json?.ready ? json : null;
  } catch {
    return null;
  }
}
