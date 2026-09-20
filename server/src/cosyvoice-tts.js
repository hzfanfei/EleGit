import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

let workerChild = null;
let workerReady = false;
let activeLayout = null;

export function setCosyVoiceLayoutForProviders(layout) {
  activeLayout = layout;
}

function trim(value) {
  return String(value || "").trim();
}

export function resolveCosyVoiceLayout(env = process.env) {
  const root = trim(env.WENXIANG_COSYVOICE_ROOT) || path.join(REPO_ROOT, "tools", "local-voice");
  const python =
    trim(env.WENXIANG_COSYVOICE_PYTHON) ||
    (process.platform === "win32"
      ? path.join(root, ".venv-cosyvoice", "Scripts", "python.exe")
      : path.join(root, ".venv-cosyvoice", "bin", "python"));
  const port = Number(trim(env.COSYVOICE_TTS_PORT) || "18787") || 18787;
  const bind = trim(env.COSYVOICE_TTS_BIND) || "127.0.0.1";
  const baseUrl = trim(env.COSYVOICE_TTS_URL) || `http://${bind}:${port}`;
  return {
    root,
    python,
    serverScript: path.join(root, "cosyvoice_server.py"),
    port,
    bind,
    baseUrl,
    modelId: trim(env.COSYVOICE_MODEL_ID) || "FunAudioLLM/Fun-CosyVoice3-0.5B-2512",
    spkId: trim(env.COSYVOICE_SPK_ID) || "zh_female_xiaohe_uranus_bigtts",
  };
}

async function waitForHealth(baseUrl, { timeoutMs = 600000, intervalMs = 500 } = {}) {
  const deadline = Date.now() + timeoutMs;
  let lastErr = "";
  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${baseUrl.replace(/\/$/, "")}/health`, {
        signal: AbortSignal.timeout(5000),
      });
      if (res.ok) {
        const json = await res.json();
        if (json?.ready) return json;
        lastErr = json?.error || "not ready";
      } else {
        lastErr = `health ${res.status}`;
      }
    } catch (err) {
      lastErr = String(err.message || err);
    }
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  throw new Error(`CosyVoice worker not ready: ${lastErr}`);
}

export async function ensureCosyVoiceTtsWorker(env = process.env) {
  if (workerReady && workerChild && !workerChild.killed) {
    return resolveCosyVoiceLayout(env);
  }
  const layout = resolveCosyVoiceLayout(env);
  if (!fs.existsSync(layout.python)) {
    throw new Error(
      `CosyVoice Python not found: ${layout.python} (run tools/local-voice/setup-cosyvoice.ps1)`,
    );
  }
  if (!fs.existsSync(layout.serverScript)) {
    throw new Error(`Missing ${layout.serverScript}`);
  }
  if (workerChild && !workerChild.killed) {
    workerChild.kill();
    workerChild = null;
  }
  workerChild = spawn(layout.python, [layout.serverScript], {
    cwd: layout.root,
    env: {
      ...env,
      COSYVOICE_TTS_PORT: String(layout.port),
      COSYVOICE_TTS_BIND: layout.bind,
      COSYVOICE_MODEL_ID: layout.modelId,
      COSYVOICE_SPK_ID: layout.spkId,
      PYTHONIOENCODING: "utf-8",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  workerChild.stdout?.on("data", (chunk) => process.stderr.write(`[cosyvoice] ${chunk}`));
  workerChild.stderr?.on("data", (chunk) => process.stderr.write(`[cosyvoice] ${chunk}`));
  workerChild.on("exit", (code) => {
    workerReady = false;
    if (code != null && code !== 0) {
      process.stderr.write(`[cosyvoice] worker exited ${code}\n`);
    }
  });
  const health = await waitForHealth(layout.baseUrl);
  workerReady = true;
  layout.health = health;
  layout.defaultSpkId = health?.default_spk || layout.spkId;
  activeLayout = layout;
  return layout;
}

export function shutdownCosyVoiceTtsWorker() {
  if (workerChild && !workerChild.killed) {
    workerChild.kill();
  }
  workerChild = null;
  workerReady = false;
  activeLayout = null;
}

export async function cosyvoiceTts(cosy, text, signal, fetchImpl = fetch) {
  const spoken = String(text || "").trim();
  if (!spoken) return Buffer.alloc(0);
  const base = cosy?.baseUrl || activeLayout?.baseUrl || resolveCosyVoiceLayout().baseUrl;
  const spkId =
    trim(cosy?.ttsVoice || cosy?.spkId) ||
    trim(activeLayout?.defaultSpkId) ||
    trim(resolveCosyVoiceLayout().spkId);
  const res = await fetchImpl(`${base.replace(/\/$/, "")}/v1/tts`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text: spoken, spk_id: spkId || undefined }),
    signal,
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    const err = new Error(`cosyvoice tts failed (${res.status})`);
    err.status = res.status;
    err.detail = detail.slice(0, 500);
    throw err;
  }
  const buf = Buffer.from(await res.arrayBuffer());
  return buf;
}
