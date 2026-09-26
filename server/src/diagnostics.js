import { mkdirSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { AcpChannel, acpEnginePreference, detectCursorEngine } from "./acp.js";
import { createVoiceProviders } from "./voice-ws.js";
import { resolveVoiceConfig, withTtsVoice } from "./voice-config.js";
import { volcTtsV3StreamLatency } from "./voice-volc.js";

const ASK_MODEL_PROMPT = "仅回复一个字：通";
const TTS_PROBE_TEXT = "通";
/** Short phrase for in-app voice preview in settings. */
export const TTS_PREVIEW_TEXT = "你好，这是音色试听。";
/** Same sentence as tools/local-voice CosyVoice latency bench for apples-to-apples TTFT. */
export const TTS_LATENCY_PROBE_TEXT = "你好，这是问象本地语音合成测试。";

function msSince(start) {
  return Date.now() - start;
}

function humanizeProbeError(err) {
  const msg = String(err || "").trim();
  if (!msg) return "检测失败";
  if (/enoent/i.test(msg) && /node(\.exe)?/i.test(msg)) {
    return "问答助手启动失败（常见原因：问象工作区目录不存在）。请确认本机工作区路径有效并已创建，然后重试。";
  }
  return msg;
}

function probeCwd(workspaceRoot) {
  if (workspaceRoot) {
    const dir = path.join(String(workspaceRoot), ".diagnostics-probe");
    mkdirSync(dir, { recursive: true });
    return dir;
  }
  return os.tmpdir();
}

/** @param {{ cwd?: string, scope?: "book"|"repo" }} [opts] */
export async function probeAskCli({ cwd, scope = "repo" } = {}) {
  const started = Date.now();
  const command = detectCursorEngine(scope);
  if (!command) {
    return {
      ok: false,
      ms: msSince(started),
      scope,
      preference: acpEnginePreference(scope),
      engine: null,
      error: "未找到本机问答助手（Claude Code 或 Cursor Agent）",
    };
  }
  const root = probeCwd(cwd);
  const channel = new AcpChannel({ command, cwd: root, idleMs: 60_000 });
  try {
    await channel.start();
    return {
      ok: true,
      ms: msSince(started),
      scope,
      preference: acpEnginePreference(scope),
      engine: command.id,
    };
  } catch (err) {
    return {
      ok: false,
      ms: msSince(started),
      scope,
      preference: acpEnginePreference(scope),
      engine: command.id,
      error: humanizeProbeError(err.message || err),
    };
  } finally {
    await channel.close().catch(() => {});
  }
}

/** @param {{ cwd?: string, scope?: "book"|"repo" }} [opts] */
export async function probeAskModel({ cwd, scope = "repo" } = {}) {
  const started = Date.now();
  const command = detectCursorEngine(scope);
  if (!command) {
    return {
      ok: false,
      ms: msSince(started),
      scope,
      preference: acpEnginePreference(scope),
      error: "未找到本机问答助手",
    };
  }
  const root = probeCwd(cwd);
  const channel = new AcpChannel({ command, cwd: root, idleMs: 60_000 });
  let snippet = "";
  try {
    await channel.start();
    await channel.prompt(ASK_MODEL_PROMPT, {
      timeoutMs: 90_000,
      onDelta: (chunk) => {
        snippet += chunk;
      },
    });
    const text = snippet.replace(/\s+/g, "").trim();
    return {
      ok: text.length > 0,
      ms: msSince(started),
      scope,
      preference: acpEnginePreference(scope),
      snippet: text.slice(0, 8),
      error: text.length > 0 ? null : "模型未返回可见文字",
    };
  } catch (err) {
    return {
      ok: false,
      ms: msSince(started),
      scope,
      preference: acpEnginePreference(scope),
      snippet: snippet.slice(0, 8),
      error: humanizeProbeError(err.message || err),
    };
  } finally {
    await channel.close().catch(() => {});
  }
}

export async function synthesizeVoicePreview({ ttsVoice, text, signal } = {}) {
  const spoken = String(text || TTS_PREVIEW_TEXT).trim().slice(0, 120);
  if (!spoken) {
    throw new Error("text is empty");
  }
  const config = withTtsVoice(resolveVoiceConfig(), ttsVoice);
  if (!config.ready) {
    throw new Error(config.hint || "语音未配置");
  }
  const { tts } = createVoiceProviders(config);
  if (!tts) {
    throw new Error("TTS 不可用");
  }
  const audio = await tts(spoken, signal);
  const bytes = audio?.length ?? 0;
  if (bytes <= 0) {
    throw new Error("合成结果为空");
  }
  return { pcm: audio, sampleRate: 24000 };
}

export async function probeVoiceTts({ ttsVoice, signal } = {}) {
  const started = Date.now();
  const config = withTtsVoice(resolveVoiceConfig(), ttsVoice);
  if (!config.ready) {
    return {
      ok: false,
      ms: msSince(started),
      provider: config.provider,
      error: config.hint || "语音未配置",
    };
  }
  const { tts } = createVoiceProviders(config);
  if (!tts) {
    return {
      ok: false,
      ms: msSince(started),
      provider: config.provider,
      error: "TTS 不可用",
    };
  }
  try {
    const audio = await tts(TTS_PROBE_TEXT, signal);
    const bytes = audio?.length ?? 0;
    return {
      ok: bytes > 0,
      ms: msSince(started),
      provider: config.provider,
      bytes,
      error: bytes > 0 ? null : "合成结果为空",
    };
  } catch (err) {
    return {
      ok: false,
      ms: msSince(started),
      provider: config.provider,
      error: String(err.message || err),
    };
  }
}

export async function probeVoiceTtsLatency({ ttsVoice, text, runs = 2, signal } = {}) {
  const probeText = String(text || TTS_LATENCY_PROBE_TEXT).trim();
  const config = withTtsVoice(resolveVoiceConfig(), ttsVoice);
  if (!config.ready) {
    return {
      ok: false,
      provider: config.provider,
      error: config.hint || "语音未配置",
      text: probeText,
      runs: [],
    };
  }
  const useVolcStream = config.provider === "volc" && config.volc?.ttsResourceId;
  const { tts } = createVoiceProviders(config);
  const outRuns = [];
  try {
    for (let i = 0; i < Math.max(1, runs); i += 1) {
      if (useVolcStream) {
        const row = await volcTtsV3StreamLatency(config.volc, probeText, signal);
        outRuns.push({
          utterance: i + 1,
          textLen: probeText.length,
          ...row,
        });
      } else {
        const started = Date.now();
        const audio = await tts(probeText, signal);
        const totalMs = msSince(started);
        outRuns.push({
          utterance: i + 1,
          textLen: probeText.length,
          ok: (audio?.length ?? 0) > 0,
          ttftMs: totalMs,
          responseMs: totalMs,
          totalMs,
          pcmBytes: audio?.length ?? 0,
          streamChunks: 1,
          sampleRate: 24000,
          note: "buffered (non-v3 stream)",
        });
      }
    }
    return {
      ok: outRuns.every((r) => r.ok),
      provider: config.provider,
      ttsVoice: config.volc?.ttsVoice || config.openai?.ttsVoice,
      text: probeText,
      stream: Boolean(useVolcStream),
      runs: outRuns,
      notes: {
        ttftMs: "POST start → first non-empty PCM chunk (v3 unidirectional stream)",
        responseMs: "POST start → HTTP response headers ready",
      },
    };
  } catch (err) {
    return {
      ok: false,
      provider: config.provider,
      text: probeText,
      runs: outRuns,
      error: String(err.message || err),
    };
  }
}

export async function probeVoiceStt({ signal } = {}) {
  const started = Date.now();
  const config = resolveVoiceConfig();
  if (!config.ready) {
    return {
      ok: false,
      ms: msSince(started),
      provider: config.provider,
      error: config.hint || "语音未配置",
    };
  }
  const { asr } = createVoiceProviders(config);
  if (!asr) {
    return {
      ok: false,
      ms: msSince(started),
      provider: config.provider,
      error: "识别不可用",
    };
  }
  try {
    await asr.start();
    asr.stop();
    return {
      ok: true,
      ms: msSince(started),
      provider: config.provider,
    };
  } catch (err) {
    try {
      asr.stop();
    } catch {
      /* ignore */
    }
    return {
      ok: false,
      ms: msSince(started),
      provider: config.provider,
      error: String(err.message || err),
    };
  } finally {
    if (signal?.aborted) {
      try {
        asr.stop();
      } catch {
        /* ignore */
      }
    }
  }
}

export async function runDiagnosticsProbe({
  workspaceRoot,
  ttsVoice,
  askCli = true,
  askModel = true,
  voiceTts = true,
  voiceStt = true,
  signal,
} = {}) {
  const cwd = probeCwd(workspaceRoot);
  const out = { at: new Date().toISOString() };
  if (askCli) {
    out.askCliBook = await probeAskCli({ cwd, scope: "book" });
    out.askCliRepo = await probeAskCli({ cwd, scope: "repo" });
    out.askCli = out.askCliRepo;
  }
  if (askModel) {
    out.askModelBook = await probeAskModel({ cwd, scope: "book" });
    out.askModelRepo = await probeAskModel({ cwd, scope: "repo" });
    out.askModel = out.askModelRepo;
  }
  if (voiceTts) out.voiceTts = await probeVoiceTts({ ttsVoice, signal });
  if (voiceStt) out.voiceStt = await probeVoiceStt({ signal });
  out.ok =
    (!askCli || (out.askCliBook?.ok === true && out.askCliRepo?.ok === true)) &&
    (!askModel || (out.askModelBook?.ok === true && out.askModelRepo?.ok === true)) &&
    (!voiceTts || out.voiceTts?.ok === true) &&
    (!voiceStt || out.voiceStt?.ok === true);
  return out;
}
