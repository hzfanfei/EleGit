// Builds the release APK, renames it to include version + build number, and
// copies the result into the local static directory used for phone downloads.
//
// Usage:
//   node scripts/build-android.mjs
//   WENXIANG_STATIC_DIR=/path/to/static node scripts/build-android.mjs
//
// Always compiles in repo-root .env (WENXIANG_PUBLIC_URL, WENXIANG_API_KEY)
// and builds arm64 only.
//
// Output naming: 问象-v<versionName>-<buildNumber>.apk
//   e.g. 问象-v0.1.0-1.apk

import { readFileSync, copyFileSync, existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

function readVersion() {
  const text = readFileSync(path.join(root, "app", "pubspec.yaml"), "utf8");
  const m = text.match(/^version:\s*([^\s#]+)/m);
  if (!m) throw new Error("pubspec.yaml 找不到 version 字段");
  const raw = m[1].trim();
  const plus = raw.indexOf("+");
  const name = plus < 0 ? raw : raw.slice(0, plus);
  const build = plus < 0 ? "" : raw.slice(plus + 1);
  if (!name) throw new Error("pubspec.yaml version 字段为空");
  return { name, build };
}

const { name, build } = readVersion();
const tag = `v${name}-${build || "0"}`;
const finalName = `问象-${tag}.apk`;

const apkSrc = path.join(
  root,
  "app",
  "build",
  "app",
  "outputs",
  "flutter-apk",
  "app-release.apk",
);

const defaultStaticDir = path.join(
  process.env.USERPROFILE || process.env.HOME || "",
  "wenxiang",
  "static",
);
const staticDir = process.env.WENXIANG_STATIC_DIR || defaultStaticDir;
const dest = path.join(staticDir, finalName);

console.log(`[build-android] version=${name} build=${build || "0"}`);
console.log(`[build-android] 输出：${dest}`);

const envFile = path.join(root, ".env");
if (!existsSync(envFile)) {
  console.error(`[build-android] 找不到 ${envFile}`);
  console.error("[build-android] 安装包需要 .env 里的 WENXIANG_PUBLIC_URL 和 WENXIANG_API_KEY");
  process.exit(1);
}
const envText = readFileSync(envFile, "utf8");
function envValue(name) {
  const line = envText.split(/\r?\n/).find((item) => item.startsWith(`${name}=`));
  if (!line) return "";
  return line.slice(name.length + 1).trim().replace(/^['"]|['"]$/g, "");
}
if (!envValue("WENXIANG_PUBLIC_URL") || !envValue("WENXIANG_API_KEY")) {
  console.error("[build-android] .env 里需要填写 WENXIANG_PUBLIC_URL 和 WENXIANG_API_KEY");
  process.exit(1);
}

const flutterBat = path.join("C:", "flutter", "bin", "flutter.bat");
const flutterArgs = [
  "build",
  "apk",
  "--release",
  "--target-platform",
  "android-arm64",
  "--dart-define-from-file=../.env",
];
console.log(`[build-android] 执行：${flutterBat} ${flutterArgs.join(" ")}`);
const r = spawnSync(flutterBat, flutterArgs, {
  cwd: path.join(root, "app"),
  stdio: "inherit",
  shell: true,
});

if (r.status !== 0) {
  console.error(`[build-android] flutter build apk 失败 (exit ${r.status})`);
  process.exit(r.status || 1);
}

if (!existsSync(apkSrc)) {
  console.error(`[build-android] 找不到产物：${apkSrc}`);
  process.exit(1);
}

mkdirSync(staticDir, { recursive: true });
copyFileSync(apkSrc, dest);
console.log(`[build-android] OK → ${dest}`);
