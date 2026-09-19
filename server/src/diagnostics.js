import os from "node:os";
import path from "node:path";
import { AcpChannel, acpEnginePreference, detectCursorEngine } from "./acp.js";
import { createVoiceProviders } from "./voice-ws.js";
import { resolveVoiceConfig, withTtsVoice } from "./voice-config.js";

const ASK_MODEL_PROMPT = "仅回复一个字：通";
const TTS_PROBE_TEXT = "通";

function msSince(start) {
  return Date.now() - start;
}

export async function probeAskCli({ cwd } = {}) {
  const started = Date.now();
  const command = detectCursorEngine();
  if (!command) {
    return {
      ok: false,
      ms: msSince(started),
      preference: acpEnginePreference(),
      engine: null,
      error: "未找到本机问答助手（Claude Code 或 Cursor Agent）",
    };
  }
  const root = String(cwd || os.tmpdir()).trim();
  const channel = new AcpChannel({ command, cwd: root, idleMs: 60_000 });
  try {
    await channel.start();
    return {
      ok: true,
      ms: msSince(started),
      preference: acpEnginePreference(),
      engine: command.id,
    };
  } catch (err) {
    return {
      ok: false,
      ms: msSince(started),
      preference: acpEnginePreference(),
      engine: command.id,
      error: String(err.message || err),
    };
  } finally {
    await channel.close().catch(() => {});
  }
}

export async function probeAskModel({ cwd } = {}) {
  const started = Date.now();
  const command = detectCursorEngine();
  if (!command) {
    return {
      ok: false,
      ms: msSince(started),
      error: "未找到本机问答助手",
    };
  }
  const root = String(cwd || os.tmpdir()).trim();
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
      snippet: text.slice(0, 8),
      error: text.length > 0 ? null : "模型未返回可见文字",
    };
  } catch (err) {
    return {
      ok: false,
      ms: msSince(started),
      snippet: snippet.slice(0, 8),
      error: String(err.message || err),
    };
  } finally {
    await channel.close().catch(() => {});
  }
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
  const cwd = workspaceRoot ? path.join(String(workspaceRoot), ".diagnostics-probe") : os.tmpdir();
  const out = { at: new Date().toISOString() };
  if (askCli) out.askCli = await probeAskCli({ cwd });
  if (askModel) out.askModel = await probeAskModel({ cwd });
  if (voiceTts) out.voiceTts = await probeVoiceTts({ ttsVoice, signal });
  if (voiceStt) out.voiceStt = await probeVoiceStt({ signal });
  out.ok =
    (!askCli || out.askCli?.ok === true) &&
    (!askModel || out.askModel?.ok === true) &&
    (!voiceTts || out.voiceTts?.ok === true) &&
    (!voiceStt || out.voiceStt?.ok === true);
  return out;
}
