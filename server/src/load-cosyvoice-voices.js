import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const CATALOG_PATH = path.join(REPO_ROOT, "tools", "local-voice", "cosyvoice_voices.json");

let cached = null;

export function loadCosyvoiceVoiceCatalog() {
  if (cached) return cached;
  const raw = fs.readFileSync(CATALOG_PATH, "utf8");
  const data = JSON.parse(raw);
  const voices = Array.isArray(data?.voices) ? data.voices : [];
  cached = {
    path: CATALOG_PATH,
    voices: voices.map((row) => ({
      id: String(row.id || "").trim(),
      name: String(row.name || row.id || "").trim(),
      scene: String(row.scene || "中文").trim(),
    })).filter((row) => row.id),
  };
  return cached;
}

export function defaultCosyvoiceVoiceId() {
  const { voices } = loadCosyvoiceVoiceCatalog();
  return voices[0]?.id || "wenxiang_default";
}
