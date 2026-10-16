const TRANSIENT = new Set([
  "UND_ERR_CONNECT_TIMEOUT",
  "UND_ERR_HEADERS_TIMEOUT",
  "UND_ERR_SOCKET",
  "ECONNRESET",
  "ECONNREFUSED",
  "ETIMEDOUT",
  "EAI_AGAIN",
  "ENOTFOUND",
  "EPIPE",
  "EHOSTUNREACH",
  "ENETUNREACH",
]);

export function fetchErrorCode(err) {
  return err?.cause?.code || err?.code || "";
}

export function isTransientFetchError(err) {
  if (err?.name === "TimeoutError") return true;
  if (TRANSIENT.has(fetchErrorCode(err))) return true;
  if (err?.name === "AbortError") return false;
  return err?.message === "fetch failed";
}

export function asFetchError(err) {
  if (!isTransientFetchError(err)) return err;
  const code = fetchErrorCode(err);
  const timedOut =
    code === "UND_ERR_CONNECT_TIMEOUT" ||
    code === "ETIMEDOUT" ||
    code === "UND_ERR_HEADERS_TIMEOUT" ||
    err?.name === "TimeoutError";
  const wrapped = new Error(timedOut ? "连接 GitHub 超时，请再试一次" : "连不上 GitHub，请再试一次");
  wrapped.status = 502;
  wrapped.code = code || "fetch_failed";
  wrapped.cause = err;
  return wrapped;
}

export async function fetchWithRetry(
  url,
  options,
  { attempts = 3, delayMs = 250, timeoutMs = 0, fetchImpl = fetch } = {},
) {
  const tries = Math.max(1, attempts);
  let last;
  for (let i = 0; i < tries; i += 1) {
    const signal = timeoutMs > 0 ? AbortSignal.timeout(timeoutMs) : options?.signal;
    try {
      return await fetchImpl(url, { ...options, signal });
    } catch (err) {
      last = err;
      if (!isTransientFetchError(err) || i === tries - 1) throw asFetchError(err);
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
  throw asFetchError(last);
}
