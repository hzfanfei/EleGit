// Builds the release APK, bumps the pubspec build number, and copies the
// result into the local static directory used for phone downloads.
//
// Usage:
//   node scripts/build-android.mjs
//   WENXIANG_STATIC_DIR=/path/to/static node scripts/build-android.mjs
//
// Always compiles in repo-root .env (WENXIANG_PUBLIC_URL, WENXIANG_API_KEY)
// and builds arm64 only. Each successful run increments the +build in
// app/pubspec.yaml. A failed run puts that number back.
//
// Output naming: 问象-v<versionName>-<buildNumber>.apk
//   e.g. 问象-v0.1.0-2.apk

import { readFileSync, writeFileSync, copyFileSync, existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const pubspecFile = path.join(root, "app", "pubspec.yaml");

export function parseVersion(text) {
  const m = String(text).match(/^version:\s*([^\s#]+)/m);
  if (!m) throw new Error("pubspec.yaml 找不到 version 字段");
  const raw = m[1].trim();
  const plus = raw.indexOf("+");
  const name = plus < 0 ? raw : raw.slice(0, plus);
  const build = plus < 0 ? "" : raw.slice(plus + 1);
  if (!name) throw new Error("pubspec.yaml version 字段为空");
  return { name, build };
}

export function nextBuildNumber(build) {
  const n = Number.parseInt(String(build || "0"), 10);
  if (!Number.isInteger(n) || n < 0) {
    throw new Error(`pubspec.yaml build 号无法递增：${build}`);
  }
  return String(n + 1);
}

export function replaceVersionLine(text, name, build) {
  const next = String(text).replace(/^version:\s*[^\s#]+/m, `version: ${name}+${build}`);
  if (next === text) throw new Error("pubspec.yaml 未能写回 version");
  return next;
}

function main() {
  const { name, build } = parseVersion(readFileSync(pubspecFile, "utf8"));
  const previous = build || "0";
  const next = nextBuildNumber(previous);
  const original = readFileSync(pubspecFile, "utf8");
  writeFileSync(pubspecFile, replaceVersionLine(original, name, next));
  console.log(`[build-android] build ${previous} → ${next}`);

  const tag = `v${name}-${next}`;
  const finalName = `问象-${tag}.apk`;
  const apkSrc = path.join(root, "app", "build", "app", "outputs", "flutter-apk", "app-release.apk");
  const defaultStaticDir = path.join(process.env.USERPROFILE || process.env.HOME || "", "wenxiang", "static");
  const staticDir = process.env.WENXIANG_STATIC_DIR || defaultStaticDir;
  const dest = path.join(staticDir, finalName);

  console.log(`[build-android] version=${name} build=${next}`);
  console.log(`[build-android] 输出：${dest}`);

  const envFile = path.join(root, ".env");
  if (!existsSync(envFile)) {
    writeFileSync(pubspecFile, original);
    console.error(`[build-android] 找不到 ${envFile}`);
    console.error("[build-android] 安装包需要 .env 里的 WENXIANG_PUBLIC_URL 和 WENXIANG_API_KEY");
    process.exit(1);
  }
  const envText = readFileSync(envFile, "utf8");
  function envValue(key) {
    const line = envText.split(/\r?\n/).find((item) => item.startsWith(`${key}=`));
    if (!line) return "";
    return line.slice(key.length + 1).trim().replace(/^['"]|['"]$/g, "");
  }
  if (!envValue("WENXIANG_PUBLIC_URL") || !envValue("WENXIANG_API_KEY")) {
    writeFileSync(pubspecFile, original);
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
    "--build-name",
    name,
    "--build-number",
    next,
    "--dart-define-from-file=../.env",
  ];
  console.log(`[build-android] 执行：${flutterBat} ${flutterArgs.join(" ")}`);
  const built = spawnSync(flutterBat, flutterArgs, {
    cwd: path.join(root, "app"),
    stdio: "inherit",
    shell: true,
  });

  if (built.status !== 0) {
    writeFileSync(pubspecFile, original);
    console.error(`[build-android] flutter build apk 失败 (exit ${built.status})，build 号已退回 ${previous}`);
    process.exit(built.status || 1);
  }

  if (!existsSync(apkSrc)) {
    writeFileSync(pubspecFile, original);
    console.error(`[build-android] 找不到产物：${apkSrc}`);
    process.exit(1);
  }

  mkdirSync(staticDir, { recursive: true });
  copyFileSync(apkSrc, dest);
  console.log(`[build-android] OK → ${dest}`);
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) main();
