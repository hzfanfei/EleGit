import { execFile, spawn } from "node:child_process";
import { promisify } from "node:util";
import { whichSync } from "./which.js";

const execFileAsync = promisify(execFile);

const NGROK_HOST = /(^|\.)ngrok(-free)?\.(dev|app|io)$/i;
export const NGROK_INSPECTOR = "http://127.0.0.1:4040";
const INSPECTOR = `${NGROK_INSPECTOR}/api/tunnels`;

export function publicHostFromUrl(url) {
  try {
    return new URL(String(url || "")).host;
  } catch {
    return "";
  }
}

export function shouldAutostartNgrok(env = process.env) {
  const flag = String(env.WENXIANG_NGROK || "").trim().toLowerCase();
  if (flag === "0" || flag === "false" || flag === "off") return false;
  if (flag === "1" || flag === "true" || flag === "on") return true;
  return NGROK_HOST.test(publicHostFromUrl(env.WENXIANG_PUBLIC_URL));
}

export function ngrokHttpArgs({ port, publicUrl }) {
  const args = ["http", String(port || 8787), "--log=stdout"];
  const host = publicHostFromUrl(publicUrl);
  if (host) args.push("--url", host);
  return args;
}

export async function fetchNgrokTunnels({
  fetchImpl = fetch,
  inspectorUrl = INSPECTOR,
} = {}) {
  try {
    const res = await fetchImpl(inspectorUrl, { signal: AbortSignal.timeout(1500) });
    if (!res?.ok) return null;
    const body = await res.json();
    return Array.isArray(body?.tunnels) ? body.tunnels : [];
  } catch {
    return null;
  }
}

export function findTunnelForPublicUrl(tunnels, publicUrl) {
  const host = publicHostFromUrl(publicUrl);
  if (!host || !Array.isArray(tunnels)) return null;
  return (
    tunnels.find((tunnel) => {
      try {
        return new URL(String(tunnel?.public_url || "")).host === host;
      } catch {
        return false;
      }
    }) ?? null
  );
}

export function ngrokTunnelReady(tunnels, { publicUrl, port = 8787 } = {}) {
  if (!Array.isArray(tunnels) || tunnels.length === 0) return false;
  const host = publicHostFromUrl(publicUrl);
  if (!host) return tunnels.length > 0;
  const tunnel = findTunnelForPublicUrl(tunnels, publicUrl);
  if (!tunnel) return false;
  const addr = String(tunnel?.config?.addr || "");
  if (!addr) return true;
  return addr.includes(String(port));
}

export async function ngrokAlreadyOpen({
  fetchImpl = fetch,
  inspectorUrl = INSPECTOR,
  publicUrl = process.env.WENXIANG_PUBLIC_URL,
  port = Number(process.env.WENXIANG_PORT || 8787),
} = {}) {
  const tunnels = await fetchNgrokTunnels({ fetchImpl, inspectorUrl });
  if (tunnels === null) return false;
  return ngrokTunnelReady(tunnels, { publicUrl, port });
}

export async function probePublicHealth(
  publicUrl,
  { fetchImpl = fetch, timeoutMs = 8000, service = "wenxiang" } = {},
) {
  const root = String(publicUrl || "").replace(/\/+$/, "");
  if (!root) return { ok: false, reason: "no-url" };
  try {
    const res = await fetchImpl(`${root}/health`, {
      headers: { "ngrok-skip-browser-warning": "true" },
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!res?.ok) return { ok: false, reason: `http-${res?.status || 0}` };
    const body = typeof res.json === "function" ? await res.json() : null;
    if (body?.ok === true && body?.service === service) return { ok: true, reason: "" };
    return { ok: false, reason: "bad-payload" };
  } catch (err) {
    return { ok: false, reason: err?.message || "fetch-failed" };
  }
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function escapeForPsRegex(text) {
  return String(text || "").replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function ngrokStopScript(host) {
  const pattern = escapeForPsRegex(host).replace(/'/g, "''");
  const list =
    "$procs = @(Get-CimInstance Win32_Process -Filter \"Name='ngrok.exe'\" -ErrorAction SilentlyContinue" +
    ` | Where-Object { $_.CommandLine -match '${pattern}' })`;
  const stop =
    "if ($procs) { $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }";
  return `${list}; ${stop}`;
}

export async function killWenxiangNgrok({
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
        ["-NoProfile", "-NonInteractive", "-Command", ngrokStopScript(host)],
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

export async function recoverNgrok({
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
  await killWenxiangNgrok({ child, env, execFileImpl, platform, settleMs });
  const deadline = Date.now() + clearTimeoutMs;
  let tunnels = await fetchNgrokTunnels({ fetchImpl });
  while (
    tunnels !== null &&
    ngrokTunnelReady(tunnels, { publicUrl, port }) &&
    Date.now() < deadline
  ) {
    await sleep(200);
    tunnels = await fetchNgrokTunnels({ fetchImpl });
  }
  if (tunnels !== null && ngrokTunnelReady(tunnels, { publicUrl, port })) {
    const err = new Error("公网隧道仍被旧 ngrok 占用，结束进程后检查口还在。");
    err.code = "NGROK_STILL_HELD";
    throw err;
  }
  return ensureNgrok({
    port,
    publicUrl,
    env,
    fetchImpl,
    spawnImpl,
    whichImpl,
    readyTimeoutMs,
  });
}

export async function ensureNgrok({
  env = process.env,
  port = Number(env.WENXIANG_PORT || 8787),
  publicUrl = env.WENXIANG_PUBLIC_URL,
  fetchImpl = fetch,
  spawnImpl = spawn,
  whichImpl = whichSync,
  readyTimeoutMs = 12_000,
} = {}) {
  if (!shouldAutostartNgrok(env)) {
    return { started: false, reason: "disabled" };
  }
  if (await ngrokAlreadyOpen({ fetchImpl, publicUrl, port })) {
    return { started: false, reason: "already" };
  }
  const bin = whichImpl(env.WENXIANG_NGROK_BIN || "ngrok");
  if (!bin) {
    const err = new Error(
      "未找到 ngrok。请先安装并执行 ngrok config add-authtoken <token>，或设 WENXIANG_NGROK=0。",
    );
    err.code = "NGROK_MISSING";
    throw err;
  }
  const args = ngrokHttpArgs({ port, publicUrl });
  const child = spawnImpl(bin, args, {
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
    env,
  });
  child.stderr?.on("data", (chunk) => {
    const text = String(chunk || "").trim();
    if (text) console.error(`[ngrok] ${text}`);
  });
  child.stdout?.on("data", (chunk) => {
    const text = String(chunk || "");
    if (text.toLowerCase().includes("err") || text.includes("started tunnel")) {
      console.error(`[ngrok] ${text.trim()}`);
    }
  });
  const deadline = Date.now() + readyTimeoutMs;
  while (Date.now() < deadline) {
    if (await ngrokAlreadyOpen({ fetchImpl, publicUrl, port })) {
      return { started: true, reason: "spawned", child };
    }
    if (child.exitCode != null) {
      const err = new Error(`ngrok 启动失败，退出码 ${child.exitCode}`);
      err.code = "NGROK_EXIT";
      throw err;
    }
    await sleep(Math.min(250, readyTimeoutMs));
  }
  console.error("[ngrok] 已拉起，但 4040 检查口还没就绪，继续启动问象服务。");
  return { started: true, reason: "spawned-unconfirmed", child };
}
