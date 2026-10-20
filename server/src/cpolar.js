import { execFile, spawn } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import { promisify } from "node:util";
import { publicHostFromUrl } from "./ngrok.js";
import { whichSync } from "./which.js";

const execFileAsync = promisify(execFile);

const CPOLAR_HOST = /(^|\.)cpolar\.(cn|top|io)$/i;
export const CPOLAR_INSPECTOR = "http://127.0.0.1:4041";

export function shouldAutostartCpolar(env = process.env) {
  const flag = String(env.WENXIANG_CPOLAR || "").trim().toLowerCase();
  if (flag === "0" || flag === "false" || flag === "off") return false;
  if (flag === "1" || flag === "true" || flag === "on") return true;
  return CPOLAR_HOST.test(publicHostFromUrl(env.WENXIANG_PUBLIC_URL));
}

/** Map a reserved cpolar hostname to CLI -subdomain / -region. */
export function cpolarTargetFromPublicUrl(publicUrl) {
  const host = publicHostFromUrl(publicUrl).toLowerCase();
  const vip = host.match(/^([a-z0-9-]+)\.vip\.cpolar\.cn$/);
  if (vip) return { subdomain: vip[1], region: "cn_vip" };
  const cn = host.match(/^([a-z0-9-]+)\.cpolar\.cn$/);
  if (cn) return { subdomain: cn[1], region: "cn" };
  const top = host.match(/^([a-z0-9-]+)\.cpolar\.top$/);
  if (top) return { subdomain: top[1], region: "cn_top" };
  const io = host.match(/^([a-z0-9-]+)\.cpolar\.io$/);
  if (io) return { subdomain: io[1], region: "us" };
  return null;
}

export function cpolarHttpArgs({ port, publicUrl, env = process.env } = {}) {
  const fromUrl = cpolarTargetFromPublicUrl(publicUrl);
  const subdomain = String(env.WENXIANG_CPOLAR_SUBDOMAIN || fromUrl?.subdomain || "").trim();
  const region = String(env.WENXIANG_CPOLAR_REGION || fromUrl?.region || "cn").trim();
  const args = ["http", String(port || 8787), "-log=stdout"];
  if (subdomain) args.push(`-subdomain=${subdomain}`);
  if (region) args.push(`-region=${region}`);
  return args;
}

export function resolveCpolarBin(env = process.env, whichImpl = whichSync) {
  const explicit = String(env.WENXIANG_CPOLAR_BIN || "").trim();
  if (explicit && existsSync(explicit)) return explicit;
  const local = path.join(env.LOCALAPPDATA || process.env.LOCALAPPDATA || "", "cpolar", "cpolar.exe");
  if (local && existsSync(local)) return local;
  return whichImpl("cpolar");
}

export async function fetchCpolarPublicUrls({
  fetchImpl = fetch,
  inspectorUrl = CPOLAR_INSPECTOR,
} = {}) {
  try {
    const res = await fetchImpl(inspectorUrl, { signal: AbortSignal.timeout(1500) });
    if (!res?.ok) return null;
    const html = await res.text();
    const found = new Set();
    for (const match of String(html).matchAll(/https?:\/\/[a-z0-9.-]+\.cpolar\.(?:cn|top|io)/gi)) {
      found.add(match[0]);
    }
    return [...found];
  } catch {
    return null;
  }
}

export function cpolarTunnelReady(urls, { publicUrl } = {}) {
  if (!Array.isArray(urls) || urls.length === 0) return false;
  const host = publicHostFromUrl(publicUrl);
  if (!host) return urls.length > 0;
  return urls.some((url) => publicHostFromUrl(url) === host);
}

export async function cpolarAlreadyOpen({
  fetchImpl = fetch,
  inspectorUrl = CPOLAR_INSPECTOR,
  publicUrl = process.env.WENXIANG_PUBLIC_URL,
} = {}) {
  const urls = await fetchCpolarPublicUrls({ fetchImpl, inspectorUrl });
  if (urls === null) return false;
  return cpolarTunnelReady(urls, { publicUrl });
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function escapeForPsRegex(text) {
  return String(text || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function cpolarStopScript(host) {
  const pattern = escapeForPsRegex(host).replace(/'/g, "''");
  const list =
    "$procs = @(Get-CimInstance Win32_Process -Filter \"Name='cpolar.exe'\" -ErrorAction SilentlyContinue" +
    ` | Where-Object { $_.CommandLine -match '${pattern}' })`;
  const stop =
    "if ($procs) { $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }";
  return `${list}; ${stop}`;
}

export async function killWenxiangCpolar({
  child = null,
  env = process.env,
  execFileImpl = execFileAsync,
  platform = process.platform,
  settleMs = 400,
} = {}) {
  let killedChild = false;
  if (child && !child.killed) {
    try {
      child.kill();
      killedChild = true;
    } catch {
      // ignore
    }
  }
  const host = publicHostFromUrl(env.WENXIANG_PUBLIC_URL);
  if (!host) {
    if (killedChild) {
      await sleep(settleMs);
      return { killed: true, method: "child" };
    }
    return { killed: false, method: "none" };
  }
  const hostMethod = platform === "win32" ? "win32-host" : "pkill";
  try {
    if (platform === "win32") {
      await execFileImpl(
        "powershell.exe",
        ["-NoProfile", "-NonInteractive", "-Command", cpolarStopScript(host)],
        { windowsHide: true },
      );
    } else {
      await execFileImpl("pkill", ["-f", host], { windowsHide: true });
    }
    await sleep(settleMs);
    return { killed: true, method: killedChild ? "child+host" : hostMethod };
  } catch {
    if (killedChild) {
      await sleep(settleMs);
      return { killed: true, method: "child" };
    }
    return { killed: false, method: `${hostMethod}-failed` };
  }
}

function attachCpolarLogs(child) {
  child.on("error", (err) => {
    console.error(`[cpolar] ${err.message || err}`);
  });
  const onChunk = (chunk) => {
    const text = String(chunk || "").trim();
    if (!text) return;
    const lower = text.toLowerCase();
    if (
      lower.includes("err") ||
      lower.includes("fail") ||
      text.includes("Tunnel established") ||
      text.includes("Authenticated")
    ) {
      console.error(`[cpolar] ${text.split(/\r?\n/).slice(-4).join(" | ")}`);
    }
  };
  child.stderr?.on("data", onChunk);
  child.stdout?.on("data", onChunk);
}

export async function ensureCpolar({
  env = process.env,
  port = Number(env.WENXIANG_PORT || 8787),
  publicUrl = env.WENXIANG_PUBLIC_URL,
  fetchImpl = fetch,
  spawnImpl = spawn,
  whichImpl = whichSync,
  readyTimeoutMs = 12_000,
} = {}) {
  if (!shouldAutostartCpolar(env)) {
    return { started: false, reason: "disabled", kind: "cpolar" };
  }
  if (await cpolarAlreadyOpen({ fetchImpl, publicUrl })) {
    return { started: false, reason: "already", kind: "cpolar" };
  }
  const target = cpolarTargetFromPublicUrl(publicUrl);
  const subdomain = String(env.WENXIANG_CPOLAR_SUBDOMAIN || target?.subdomain || "").trim();
  if (!subdomain) {
    const err = new Error("WENXIANG_PUBLIC_URL 不是可识别的 cpolar 固定域名，无法拉起隧道。");
    err.code = "CPOLAR_NO_SUBDOMAIN";
    throw err;
  }
  const bin = resolveCpolarBin(env, whichImpl);
  if (!bin) {
    const err = new Error(
      "未找到 cpolar。请安装客户端并执行 cpolar authtoken <token>，或设 WENXIANG_CPOLAR=0。",
    );
    err.code = "CPOLAR_MISSING";
    throw err;
  }
  const args = cpolarHttpArgs({ port, publicUrl, env });
  const child = spawnImpl(bin, args, {
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
    env,
  });
  attachCpolarLogs(child);
  const deadline = Date.now() + readyTimeoutMs;
  while (Date.now() < deadline) {
    if (await cpolarAlreadyOpen({ fetchImpl, publicUrl })) {
      return { started: true, reason: "spawned", kind: "cpolar", child };
    }
    if (child.exitCode != null) {
      const err = new Error(`cpolar 启动失败，退出码 ${child.exitCode}`);
      err.code = "CPOLAR_EXIT";
      throw err;
    }
    await sleep(Math.min(250, readyTimeoutMs));
  }
  console.error("[cpolar] 已拉起，但 4041 检查口还没就绪，继续启动问象服务。");
  return { started: true, reason: "spawned-unconfirmed", kind: "cpolar", child };
}

export async function recoverCpolar({
  child = null,
  port = Number(process.env.WENXIANG_PORT || 8787),
  publicUrl = process.env.WENXIANG_PUBLIC_URL,
  env = process.env,
  fetchImpl = fetch,
  spawnImpl = spawn,
  whichImpl = whichSync,
  execFileImpl = execFileAsync,
  platform = process.platform,
  settleMs = 400,
  clearTimeoutMs = 5000,
  readyTimeoutMs = 12_000,
} = {}) {
  await killWenxiangCpolar({ child, env, execFileImpl, platform, settleMs });
  const deadline = Date.now() + clearTimeoutMs;
  let urls = await fetchCpolarPublicUrls({ fetchImpl });
  while (urls !== null && cpolarTunnelReady(urls, { publicUrl }) && Date.now() < deadline) {
    await sleep(200);
    urls = await fetchCpolarPublicUrls({ fetchImpl });
  }
  if (urls !== null && cpolarTunnelReady(urls, { publicUrl })) {
    const err = new Error("公网隧道仍被旧 cpolar 占用，结束进程后检查口还在。");
    err.code = "CPOLAR_STILL_HELD";
    throw err;
  }
  return ensureCpolar({
    port,
    publicUrl,
    env,
    fetchImpl,
    spawnImpl,
    whichImpl,
    readyTimeoutMs,
  });
}
