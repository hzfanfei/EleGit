import { spawn } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

let workerChild = null;
let workerReady = false;
let activeLayout = null;

const PARTIAL_INTERVAL_MS = 650;
const MIN_PARTIAL_BYTES = 16000 * 2; // 1s @ 16kHz s16le
const ENDPOINT_SILENCE_MS = 1200;

export function setFunasrLayoutForProviders(layout) {
  activeLayout = layout;
}

function trim(value) {
  return String(value || "").trim();
}

export function resolveFunasrLayout(env = process.env) {
  const root = trim(env.WENXIANG_FUNASR_ROOT) || path.join(REPO_ROOT, "tools", "local-voice");
  const python =
    trim(env.WENXIANG_FUNASR_PYTHON) ||
    (process.platform === "win32"
      ? path.join(root, ".venv", "Scripts", "python.exe")
      : path.join(root, ".venv", "bin", "python"));
  const port = Number(trim(env.FUNASR_ASR_PORT) || "18788") || 18788;
  const bind = trim(env.FUNASR_ASR_BIND) || "127.0.0.1";
  const baseUrl = trim(env.FUNASR_ASR_URL) || `http://${bind}:${port}`;
  return {
    root,
    python,
    serverScript: path.join(root, "funasr_server.py"),
    port,
    bind,
    baseUrl,
    modelId: trim(env.FUNASR_MODEL_ID) || "paraformer-zh",
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
  throw new Error(`FunASR worker not ready: ${lastErr}`);
}

export async function ensureFunasrAsrWorker(env = process.env) {
  if (workerReady && workerChild && !workerChild.killed) {
    return resolveFunasrLayout(env);
  }
  const layout = resolveFunasrLayout(env);
  if (!fs.existsSync(layout.python)) {
    throw new Error(`FunASR Python not found: ${layout.python} (run tools/local-voice/setup.ps1)`);
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
      FUNASR_ASR_PORT: String(layout.port),
      FUNASR_ASR_BIND: layout.bind,
      FUNASR_MODEL_ID: layout.modelId,
      PYTHONIOENCODING: "utf-8",
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  workerChild.stdout?.on("data", (chunk) => process.stderr.write(`[funasr] ${chunk}`));
  workerChild.stderr?.on("data", (chunk) => process.stderr.write(`[funasr] ${chunk}`));
  workerChild.on("exit", (code) => {
    workerReady = false;
    if (code != null && code !== 0) {
      process.stderr.write(`[funasr] worker exited ${code}\n`);
    }
  });
  const health = await waitForHealth(layout.baseUrl);
  workerReady = true;
  layout.health = health;
  activeLayout = layout;
  return layout;
}

export function shutdownFunasrAsrWorker() {
  if (workerChild && !workerChild.killed) {
    workerChild.kill();
  }
  workerChild = null;
  workerReady = false;
  activeLayout = null;
}

async function funasrInfer(baseUrl, pcm, { final = true, signal, fetchImpl = fetch } = {}) {
  const res = await fetchImpl(`${baseUrl.replace(/\/$/, "")}/v1/asr`, {
    method: "POST",
    headers: {
      "Content-Type": "application/octet-stream",
      "X-Final": final ? "1" : "0",
    },
    body: pcm,
    signal,
  });
  if (!res.ok) {
    const detail = await res.text().catch(() => "");
    const err = new Error(`funasr asr failed (${res.status})`);
    err.status = res.status;
    err.detail = detail.slice(0, 500);
    throw err;
  }
  return res.json();
}

export function createFunasrAsr({
  funasr,
  pushToTalk = false,
  onPartial,
  onFinal,
  onError,
  fetchImpl = fetch,
} = {}) {
  const chunks = [];
  let started = false;
  let partialTimer = null;
  let lastPartial = "";
  let inferChain = Promise.resolve();
  let endpointTimer = null;

  function baseUrl() {
    return funasr?.baseUrl || activeLayout?.baseUrl || resolveFunasrLayout().baseUrl;
  }

  function pcmBuffer() {
    return chunks.length ? Buffer.concat(chunks) : Buffer.alloc(0);
  }

  function queueInfer(final, { endpoint = false } = {}) {
    const buf = pcmBuffer();
    inferChain = inferChain
      .then(async () => {
        if (!started && !final) return;
        if (!buf.length) {
          if (final) onFinal?.("");
          return;
        }
        const json = await funasrInfer(baseUrl(), buf, { final, fetchImpl });
        const text = String(json?.text || "").trim();
        if (!text) {
          if (final) onFinal?.("");
          if (endpoint) {
            chunks.length = 0;
            lastPartial = "";
          }
          return;
        }
        if (final) {
          onFinal?.(text);
        } else if (text !== lastPartial) {
          lastPartial = text;
          onPartial?.(text);
        }
        if (endpoint && !pushToTalk) {
          chunks.length = 0;
          lastPartial = "";
        }
      })
      .catch((err) => {
        onError?.({ message: String(err.message || err), err });
      });
    return inferChain;
  }

  function clearPartialTimer() {
    if (partialTimer) {
      clearInterval(partialTimer);
      partialTimer = null;
    }
  }

  function clearEndpointTimer() {
    if (endpointTimer) {
      clearTimeout(endpointTimer);
      endpointTimer = null;
    }
  }

  function scheduleEndpoint() {
    if (pushToTalk) return;
    clearEndpointTimer();
    if (!started) return;
    endpointTimer = setTimeout(() => {
      if (!started || pcmBuffer().length < MIN_PARTIAL_BYTES) return;
      queueInfer(true, { endpoint: true });
    }, ENDPOINT_SILENCE_MS);
  }

  return {
    async start() {
      chunks.length = 0;
      lastPartial = "";
      started = true;
      inferChain = Promise.resolve();
      clearPartialTimer();
      clearEndpointTimer();
      partialTimer = setInterval(() => {
        if (!started || pcmBuffer().length < MIN_PARTIAL_BYTES) return;
        queueInfer(false);
      }, PARTIAL_INTERVAL_MS);
    },
    push(pcm) {
      if (!started) return;
      chunks.push(Buffer.isBuffer(pcm) ? pcm : Buffer.from(pcm));
      if (!pushToTalk) scheduleEndpoint();
    },
    stop() {
      started = false;
      clearPartialTimer();
      clearEndpointTimer();
      chunks.length = 0;
      lastPartial = "";
    },
    async finalize() {
      started = false;
      clearPartialTimer();
      clearEndpointTimer();
      await queueInfer(true);
      chunks.length = 0;
      lastPartial = "";
    },
  };
}
