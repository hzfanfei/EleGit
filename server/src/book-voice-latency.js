/** How book voice-turn is wired today (see book-voice-turn.js). */
export const BOOK_VOICE_SPEAK_STRATEGY = "stream";

/** App enqueues PCM on each SSE `audio` event (book_quick_voice_session.dart). */
export const BOOK_VOICE_CLIENT_WAITS_FOR_DONE = false;

/**
 * @typedef {{ phase: string, atMs: number }} LatencyMarker
 */

/**
 * Summarize where wall-clock time goes before the user hears audio.
 * @param {LatencyMarker[]} markers
 * @param {{ clientWaitsForDone?: boolean, speakStrategy?: string }} opts
 */
export function diagnoseBookVoiceLatency(markers, opts = {}) {
  const clientWaitsForDone = opts.clientWaitsForDone ?? BOOK_VOICE_CLIENT_WAITS_FOR_DONE;
  const speakStrategy = opts.speakStrategy ?? BOOK_VOICE_SPEAK_STRATEGY;
  if (!markers?.length) {
    return {
      buckets: {},
      reasons: ["无时间线数据"],
      timeToFirstAudioMs: null,
      timeToTurnDoneMs: null,
      dominant: "unknown",
    };
  }

  const sorted = [...markers].sort((a, b) => a.atMs - b.atMs);
  const t0 = sorted[0].atMs;
  const at = (phase) => {
    const hit = sorted.find((m) => m.phase === phase);
    return hit ? hit.atMs - t0 : null;
  };

  const turnStart = 0;
  const askDone = at("ask_done");
  const firstAudio = at("first_audio");
  const turnDone = at("turn_done");

  const buckets = {
    thinkUntilAskDone: askDone ?? null,
    ttsAfterAskUntilFirstAudio:
      askDone != null && firstAudio != null ? Math.max(0, firstAudio - askDone) : null,
    sseAfterFirstAudioUntilDone:
      firstAudio != null && turnDone != null ? Math.max(0, turnDone - firstAudio) : null,
    totalUntilFirstAudio: firstAudio ?? null,
    totalUntilTurnDone: turnDone ?? null,
  };

  const reasons = [];

  if (speakStrategy === "final") {
    reasons.push(
      "服务端 speakStrategy=final：必须等 ACP 整段回答生成完毕，才做一次（或分段串行）TTS，首段音频不会早于「思考完成」。",
    );
  } else {
    reasons.push(
      "服务端 speakStrategy=stream：可在 ACP 流式出字时提前 TTS，首段音频通常早于整段回答结束。",
    );
  }

  if (clientWaitsForDone) {
    reasons.push(
      "App 端在收到 SSE done 后才合并 PCM 并播放；audio 事件先到也不会出声，用户感知等待 ≈ 连接 + 整段思考 + 整段 TTS + 收包。",
    );
  } else {
    reasons.push(
      "App 端在收到 SSE audio 即入队播放，首声通常只需等到第一段可朗读 TTS 返回。",
    );
  }

  reasons.push(
    "真实环境还有：书目录 materialize、session warm、火山 TTS 网络 RTT；长回答会 splitTextForTts 多段串行合成。",
  );

  let dominant = "think_acp";
  const think = buckets.thinkUntilAskDone ?? 0;
  const tts = buckets.ttsAfterAskUntilFirstAudio ?? 0;
  if (tts > think && tts > 0) dominant = "tts";
  if (clientWaitsForDone && (buckets.sseAfterFirstAudioUntilDone ?? 0) > think && (buckets.sseAfterFirstAudioUntilDone ?? 0) > tts) {
    dominant = "client_buffer_until_done";
  }

  const userPerceivedFirstSoundMs = clientWaitsForDone
    ? turnDone ?? firstAudio
    : firstAudio;

  return {
    buckets,
    reasons,
    timeToFirstAudioMs: firstAudio,
    timeToTurnDoneMs: turnDone,
    userPerceivedFirstSoundMs,
    dominant,
    speakStrategy,
    clientWaitsForDone,
    timeline: sorted.map((m) => ({ phase: m.phase, ms: m.atMs - t0 })),
  };
}

/**
 * @param {Array<{ label: string } & ReturnType<typeof diagnoseBookVoiceLatency>>} rows
 */
export function formatLatencyComparison(rows) {
  const lines = [
    "=== 快问快答延迟对比（同一模拟 ACP 时间线）===",
    "",
    "方案 | 首包 audio(SSE) | 用户首声(感知) | 回合结束 | ACP 结束",
    "---|---:|---:|---:|---:",
  ];
  for (const r of rows) {
    const hear = r.userPerceivedFirstSoundMs ?? r.timeToFirstAudioMs;
    lines.push(
      `${r.label} | ${Math.round(r.timeToFirstAudioMs ?? 0)} | ${Math.round(hear ?? 0)} | ${Math.round(r.timeToTurnDoneMs ?? 0)} | ${Math.round(r.buckets.thinkUntilAskDone ?? 0)}`,
    );
  }
  const base = rows[0]?.userPerceivedFirstSoundMs ?? rows[0]?.timeToFirstAudioMs;
  const cur = rows[rows.length - 1]?.userPerceivedFirstSoundMs ?? rows[rows.length - 1]?.timeToFirstAudioMs;
  if (base != null && cur != null && base > 0) {
    const saved = base - cur;
    const pct = Math.round((saved / base) * 100);
    lines.push("");
    lines.push(
      `当前方案相对「${rows[0].label}」：首声约快 ${Math.round(saved)}ms（约 ${pct}%）`,
    );
  }
  return lines.join("\n");
}

/** @param {LatencyMarker[]} markers */
export function formatLatencyDiagnosis(report) {
  const lines = [
    "=== 快问快答等待时间诊断 ===",
    `策略: speakStrategy=${report.speakStrategy}, App 等 done 再播=${report.clientWaitsForDone}`,
    "阶段耗时(ms):",
  ];
  for (const [k, v] of Object.entries(report.buckets)) {
    if (v != null) lines.push(`  ${k}: ${v}`);
  }
  lines.push(`主要瓶颈(模拟): ${report.dominant}`);
  lines.push("原因:");
  for (const r of report.reasons) lines.push(`  - ${r}`);
  if (report.timeline?.length) {
    lines.push("时间线:");
    for (const e of report.timeline) lines.push(`  ${e.ms}ms  ${e.phase}`);
  }
  return lines.join("\n");
}
