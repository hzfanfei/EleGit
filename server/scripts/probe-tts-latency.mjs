#!/usr/bin/env node
/**
 * Volc / OpenAI TTS latency (TTFT) — aligned with tools/local-voice/bench_cosyvoice3_latency.py
 */
import dotenv from "dotenv";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { probeVoiceTtsLatency } from "../src/diagnostics.js";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
dotenv.config({ path: path.join(repoRoot, ".env") });

const text = process.argv.slice(2).join(" ").trim() || undefined;
const report = await probeVoiceTtsLatency({ text, runs: 2 });
console.log(JSON.stringify(report, null, 2));
process.exit(report.ok ? 0 : 1);
