import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const envPath = existsSync(path.join(root, ".env"))
  ? path.join(root, ".env")
  : path.join(root, ".env.example");

const parsed = {};
for (const line of readFileSync(envPath, "utf8").split(/\r?\n/)) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith("#")) continue;
  const eq = trimmed.indexOf("=");
  if (eq < 1) continue;
  parsed[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
}

const publicUrl = (parsed.WENXIANG_PUBLIC_URL || "https://nonstrategically-pulverable-libby.ngrok-free.dev").replace(
  /\/+$/,
  "",
);
const apiKey = parsed.WENXIANG_API_KEY || "";

const outDir = path.join(root, "app", "lib", "generated");
mkdirSync(outDir, { recursive: true });
const dart = `// Generated from ${path.basename(envPath)}. Do not commit.
const kSyncedPublicUrl = ${JSON.stringify(publicUrl)};
const kSyncedApiKey = ${JSON.stringify(apiKey)};
`;
writeFileSync(path.join(outDir, "env.g.dart"), dart);
console.log(`Wrote app/lib/generated/env.g.dart from ${path.relative(root, envPath)}`);
