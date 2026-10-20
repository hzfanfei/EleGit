import { execFile, spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { publicHostFromUrl } from "./ngrok.js";
import { whichSync } from "./which.js";

const execFileAsync = promisify(execFile);

const CPOLAR_HOST = /(^|\.)cpolar\.(cn|top|io)$/i;
export const CPOLAR_INSPECTOR = "http://127.0.0.1:4040";
const CPOLAR_INSPECTORS = [CPOLAR_INSPECTOR, "http://127.0.0.1:4041"];

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

export function cpolarConfigPath(env = process.env) {
  const home = env.USERPROFILE || env.HOME || os.homedir();
  return path.join(home, ".cpolar", "cpolar.yml");
}

/** When the user config lists tunnels, one process must serve all of them. */
export function cpolarLaunchArgs({ port, publicUrl, env = process.env, configText = "" } = {}) {
  if (/^\s*tunnels\s*:/m.test(String(configText || ""))) return ["start-all", "-log=stdout"];
  return cpolarHttpArgs({ port, publicUrl, env });
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
  inspectorUrl = "",
} = {}) {
  const targets = inspectorUrl ? [inspectorUrl] : CPOLAR_INSPECTORS;
  let sawInspector = false;
  const found = new Set();
  for (const target of targets) {
    try {
      const res = await fetchImpl(target, { signal: AbortSignal.timeout(1500) });
      if (!res?.ok) continue;
      const html = await res.text();
      if (!/cpolar/i.test(html)) continue;
      sawInspector = true;
      for (const match of html.matchAll(/https?:\/\/[a-z0-9.-]+\.cpolar\.(?:cn|top|io)/gi)) {
        found.add(match[0]);
      }
    } catch {
      // try the next inspector port
    }
  }
  return sawInspector ? [...found] : null;
}

export function cpolarTunnelReady(urls, { publicUrl } = {}) {
  if (!Array.isArray(urls) || urls.length === 0) return false;
  const host = publicHostFromUrl(publicUrl);
  if (!host) return urls.length > 0;
  return urls.some((url) => publicHostFromUrl(url) === host);
}

async function cpolarProcessAlive(execFileImpl = execFileAsync) {
  if (process.platform !== "win32") return false;
  try {
    const { stdout } = await execFileImpl(
      "powershell.exe",
      [
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "@(Get-Process cpolar -ErrorAction SilentlyContinue).Count",
      ],
      { windowsHide: true },
    );
    return Number(String(stdout || "").trim()) > 0;
  } catch {
    return false;
  }
}

export async function cpolarAlreadyOpen({
  fetchImpl = fetch,
  inspectorUrl = "",
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
    ` | Where-Object { $_.CommandLine -match '${pattern}' -or $_.CommandLine -match 'start-all' })`;
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
  const readyDeadline = Date.now() + readyTimeoutMs;
  while (Date.now() < readyDeadline) {
    if (await cpolarAlreadyOpen({ fetchImpl, publicUrl })) {
      return { started: false, reason: "already", kind: "cpolar" };
    }
    if (!(await cpolarProcessAlive(execFileAsync))) break;
    await sleep(250);
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
  let configText = "";
  try {
    configText = readFileSync(cpolarConfigPath(env), "utf8");
  } catch {
    configText = "";
  }
  const args = cpolarLaunchArgs({ port, publicUrl, env, configText });
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
