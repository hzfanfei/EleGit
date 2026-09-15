import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { config as loadDotenv } from "dotenv";

export function defaultEnvFile() {
  if (process.env.WENXIANG_ENV_FILE) return process.env.WENXIANG_ENV_FILE;
  const serverRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
  return path.join(serverRoot, ".env");
}

/** Load server/.env into process.env. Existing env vars are not overwritten. */
export function loadLocalEnv(file = defaultEnvFile()) {
  if (!file || !existsSync(file)) return { loaded: false, file };
  loadDotenv({ path: file, override: false, quiet: true });
  return { loaded: true, file };
}
