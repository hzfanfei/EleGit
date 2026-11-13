import { AcpChannel, resolveCodexAgentCommand } from "./acp.js";
import { mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export async function measureModelSpeed(scope, { command = resolveCodexAgentCommand(scope), Channel = AcpChannel } = {}) {
  if (!command) throw new Error("Codex unavailable");
  const cwd = path.join(os.tmpdir(), "wenxiang-model-speed");
  await mkdir(cwd, { recursive: true });
  const channel = new Channel({ command, cwd, readOnly: true, idleMs: 0 });
  let first = 0, last = 0, text = "";
  try {
    await channel.start();
    const started = performance.now();
    const response = await channel.prompt("Do not use tools. Output a numbered list of 80 short English sentences about everyday objects, one sentence per line. No introduction or conclusion.", {
      timeoutMs: 120000,
      onDelta: chunk => { const now = performance.now(); if (!first) first = now; last = now; text += chunk; },
    });
    if (!text.trim()) throw new Error("Model returned no text");
    const elapsedMs = performance.now() - started;
    const outputTokens = response?.usage?.outputTokens;
    const measured = Number.isFinite(outputTokens) && outputTokens > 0;
    // Never present a character-based estimate as provider token usage.
    return { scope, model: command.model, outputTokens: measured ? outputTokens : null,
      tokensPerSecond: measured && last > first ? outputTokens / ((last - first) / 1000) : null,
      firstTokenMs: first - started, generationMs: last - first, elapsedMs, characters: [...text].length,
      note: measured ? null : "Provider did not report output token usage" };
  } finally { await channel.close().catch(() => {}); }
}
