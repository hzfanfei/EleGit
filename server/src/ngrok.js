import { spawn } from "node:child_process";
import { whichSync } from "./which.js";

const NGROK_HOST = /(^|\.)ngrok(-free)?\.(dev|app|io)$/i;
const INSPECTOR = "http://127.0.0.1:4040/api/tunnels";

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

export async function ngrokAlreadyOpen({
  fetchImpl = fetch,
  inspectorUrl = INSPECTOR,
} = {}) {
  try {
    const res = await fetchImpl(inspectorUrl, { signal: AbortSignal.timeout(1500) });
    if (!res?.ok) return false;
    const body = await res.json();
    return Array.isArray(body?.tunnels) && body.tunnels.length > 0;
  } catch {
    return false;
  }
}

export async function ensureNgrok({
  port = Number(process.env.WENXIANG_PORT || 8787),
  publicUrl = process.env.WENXIANG_PUBLIC_URL,
  env = process.env,
  fetchImpl = fetch,
  spawnImpl = spawn,
  whichImpl = whichSync,
} = {}) {
  if (!shouldAutostartNgrok(env)) {
    return { started: false, reason: "disabled" };
  }
  if (await ngrokAlreadyOpen({ fetchImpl })) {
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
  const deadline = Date.now() + 12_000;
  while (Date.now() < deadline) {
    if (await ngrokAlreadyOpen({ fetchImpl })) {
      return { started: true, reason: "spawned", child };
    }
    if (child.exitCode != null) {
      const err = new Error(`ngrok 启动失败，退出码 ${child.exitCode}`);
      err.code = "NGROK_EXIT";
      throw err;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  console.error("[ngrok] 已拉起，但 4040 检查口还没就绪，继续启动问象服务。");
  return { started: true, reason: "spawned-unconfirmed", child };
}
