import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadDotenv } from "dotenv";

export const DEFAULT_PUBLIC_URL = "https://wenxiang.ngrok.app";

export function repoRoot() {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
}

export function defaultEnvFile() {
  if (process.env.WENXIANG_ENV_FILE) return process.env.WENXIANG_ENV_FILE;
  const rootEnv = path.join(repoRoot(), ".env");
  const serverEnv = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", ".env");
  if (existsSync(rootEnv)) return rootEnv;
  return serverEnv;
}

/** Load root .env (then server/.env fallback) into process.env. Existing env wins. */
export function loadLocalEnv(file = defaultEnvFile()) {
  if (!file || !existsSync(file)) return { loaded: false, file };
  loadDotenv({ path: file, override: false, quiet: true });
  return { loaded: true, file };
}

export function publicUrlFromEnv() {
  return String(process.env.WENXIANG_PUBLIC_URL || DEFAULT_PUBLIC_URL).replace(/\/+$/, "");
}
