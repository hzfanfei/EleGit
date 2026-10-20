import {
  cpolarTunnelReady,
  ensureCpolar,
  fetchCpolarPublicUrls,
  killWenxiangCpolar,
  recoverCpolar,
  shouldAutostartCpolar,
} from "./cpolar.js";
import {
  ensureNgrok,
  fetchNgrokTunnels,
  killWenxiangNgrok,
  ngrokTunnelReady,
  probePublicHealth,
  recoverNgrok,
  shouldAutostartNgrok,
} from "./ngrok.js";

export { probePublicHealth };

export function publicTunnelKind(env = process.env) {
  if (shouldAutostartCpolar(env)) return "cpolar";
  if (shouldAutostartNgrok(env)) return "ngrok";
  return "";
}

export function shouldAutostartPublicTunnel(env = process.env) {
  return Boolean(publicTunnelKind(env));
}

/** ready: expected host is up. mismatch: inspector up but wrong host. down: no inspector. */
export async function inspectPublicTunnel({
  env = process.env,
  publicUrl = env.WENXIANG_PUBLIC_URL,
  port = Number(env.WENXIANG_PORT || 8787),
  fetchImpl = fetch,
} = {}) {
  if (shouldAutostartCpolar(env)) {
    const urls = await fetchCpolarPublicUrls({ fetchImpl });
    if (urls === null) return "down";
    return cpolarTunnelReady(urls, { publicUrl }) ? "ready" : "mismatch";
  }
  const tunnels = await fetchNgrokTunnels({ fetchImpl });
  if (tunnels === null) return "down";
  return ngrokTunnelReady(tunnels, { publicUrl, port }) ? "ready" : "mismatch";
}

export async function ensurePublicTunnel(opts = {}) {
  const env = opts.env || process.env;
  if (shouldAutostartCpolar(env)) return ensureCpolar(opts);
  return ensureNgrok(opts);
}

export async function recoverPublicTunnel(opts = {}) {
  const env = opts.env || process.env;
  if (shouldAutostartCpolar(env)) return recoverCpolar(opts);
  return recoverNgrok(opts);
}

export async function killPublicTunnel(opts = {}) {
  const env = opts.env || process.env;
  if (shouldAutostartCpolar(env)) return killWenxiangCpolar(opts);
  return killWenxiangNgrok(opts);
}
