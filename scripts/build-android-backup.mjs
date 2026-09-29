// One-off-style backup APK: different package id, label, icon, release signing.
// Does not bump pubspec. Restores all touched repo files after build.
//
// Usage: node scripts/build-android-backup.mjs

import {
  readFileSync,
  writeFileSync,
  copyFileSync,
  existsSync,
  mkdirSync,
  rmSync,
  statSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { deflateSync } from "node:zlib";

import { parseVersion } from "./build-android.mjs";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const pubspecFile = path.join(root, "app", "pubspec.yaml");
const gradleFile = path.join(root, "app", "android", "app", "build.gradle.kts");
const manifestFile = path.join(root, "app", "android", "app", "src", "main", "AndroidManifest.xml");
const colorsFile = path.join(root, "app", "android", "app", "src", "main/res/values/colors.xml");
const resRoot = path.join(root, "app", "android", "app", "src", "main", "res");

const BACKUP_APP_ID = "cn.wenxiang.wenxiang.backup";
const BACKUP_LABEL = "问象·备";
const tempDir = path.join(process.env.TEMP || "", "wenxiang-backup-sign");
const keystore = path.join(tempDir, "backup-release.keystore");
const keyPropsFile = path.join(root, "app", "android", "key.properties");

const BACKUP_SURFACE = [0x24, 0x30, 0x28, 0xff];
const BACKUP_ACCENT = [0x6b, 0x9e, 0x78, 0xff];
const BACKUP_BADGE = [0xc4, 0xe8, 0xcf, 0xff];

function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (c & 1 ? 0xedb88320 : 0);
  }
  return ~c >>> 0;
}

function pngChunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const body = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(body));
  return Buffer.concat([len, body, crc]);
}

function encodePng(width, height, rgba) {
  const stride = width * 4 + 1;
  const raw = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    raw[y * stride] = 0;
    rgba.copy(raw, y * stride + 1, y * width * 4, (y + 1) * width * 4);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", ihdr),
    pngChunk("IDAT", deflateSync(raw)),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

function blend(dst, i, color, alpha) {
  if (alpha <= 0) return;
  const a = Math.min(1, alpha);
  dst[i] = Math.round(dst[i] * (1 - a) + color[0] * a);
  dst[i + 1] = Math.round(dst[i + 1] * (1 - a) + color[1] * a);
  dst[i + 2] = Math.round(dst[i + 2] * (1 - a) + color[2] * a);
  dst[i + 3] = 255;
}

function roundedRectCoverage(px, py, x, y, w, h, r) {
  const cx = Math.min(Math.max(px, x + r), x + w - r);
  const cy = Math.min(Math.max(py, y + r), y + h - r);
  const insideX = px >= x + r && px <= x + w - r;
  const insideY = py >= y + r && py <= y + h - r;
  if (insideX && insideY) return 1;
  if (insideX && py >= y && py <= y + h) return 1;
  if (insideY && px >= x && px <= x + w) return 1;
  const dx = px - cx;
  const dy = py - cy;
  const d = Math.hypot(dx, dy) - r;
  if (d >= 1) return 0;
  if (d <= -1) return 1;
  return 1 - (d + 1) / 2;
}

function renderBackupMark(size) {
  const rgba = Buffer.alloc(size * size * 4);
  for (let i = 0; i < rgba.length; i += 4) {
    rgba[i] = BACKUP_SURFACE[0];
    rgba[i + 1] = BACKUP_SURFACE[1];
    rgba[i + 2] = BACKUP_SURFACE[2];
    rgba[i + 3] = 255;
  }
  const inset = 0.16;
  const x0 = size * inset;
  const y0 = size * inset;
  const inner = size * (1 - inset * 2);
  const radius = inner * 0.08;
  const stroke = Math.max(1, inner * 0.07);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const px = x + 0.5;
      const py = y + 0.5;
      const outer = roundedRectCoverage(px, py, x0, y0, inner, inner, radius);
      const holeR = Math.max(0, radius - stroke);
      const hole = roundedRectCoverage(
        px,
        py,
        x0 + stroke,
        y0 + stroke,
        inner - stroke * 2,
        inner - stroke * 2,
        holeR,
      );
      const frame = Math.max(0, outer - hole);
      if (frame > 0) blend(rgba, (y * size + x) * 4, BACKUP_ACCENT, frame);
      const barW = Math.max(1.6, inner * 0.075);
      const barH = inner * 0.48;
      const barX = x0 + (inner - barW) / 2;
      const barY = y0 + inner * 0.26;
      const bar = roundedRectCoverage(px, py, barX, barY, barW, barH, Math.min(barW / 2, 0.8));
      if (bar > 0) blend(rgba, (y * size + x) * 4, BACKUP_ACCENT, bar);
      const hW = inner * 0.48;
      const hH = Math.max(1.6, inner * 0.075);
      const hX = x0 + inner * 0.26;
      const hY = y0 + (inner - hH) / 2;
      const hBar = roundedRectCoverage(px, py, hX, hY, hW, hH, Math.min(hH / 2, 0.8));
      if (hBar > 0) blend(rgba, (y * size + x) * 4, BACKUP_ACCENT, hBar);
      const badge = inner * 0.28;
      const bx = x0 + inner - badge * 0.92;
      const by = y0 + inner * 0.06;
      const bCov = roundedRectCoverage(px, py, bx, by, badge, badge, badge * 0.22);
      if (bCov > 0) blend(rgba, (y * size + x) * 4, BACKUP_BADGE, bCov);
    }
  }
  return rgba;
}

const backupResFiles = [];
const originals = new Map();

function snapshot(file) {
  originals.set(file, readFileSync(file, "utf8"));
}

function restoreAll() {
  for (const [file, text] of originals) {
    writeFileSync(file, text);
  }
  for (const f of backupResFiles) {
    if (existsSync(f)) rmSync(f);
  }
  if (existsSync(keyPropsFile)) rmSync(keyPropsFile);
  if (existsSync(tempDir)) rmSync(tempDir, { recursive: true, force: true });
}

function writeBackupResources() {
  const fgXml = `<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#6B9E78"
        android:fillType="evenOdd"
        android:pathData="M38,34 H70 A4,4 0 0 1 74,38 V70 A4,4 0 0 1 70,74 H38 A4,4 0 0 1 34,70 V38 A4,4 0 0 1 38,34 Z M39,37 H69 A2,2 0 0 1 71,39 V69 A2,2 0 0 1 69,71 H39 A2,2 0 0 1 37,69 V39 A2,2 0 0 1 39,37 Z" />
    <path android:fillColor="#6B9E78" android:pathData="M52.5,44.4 H55.5 V63.6 H52.5 Z" />
    <path android:fillColor="#6B9E78" android:pathData="M44.4,52.5 H63.6 V55.5 H44.4 Z" />
    <path android:fillColor="#C4E8CF" android:pathData="M62,36 H74 A3,3 0 0 1 77,39 V51 A3,3 0 0 1 74,54 H62 A3,3 0 0 1 59,51 V39 A3,3 0 0 1 62,36 Z" />
</vector>
`;
  const fgPath = path.join(resRoot, "drawable/ic_launcher_foreground_backup.xml");
  writeFileSync(fgPath, fgXml);
  backupResFiles.push(fgPath);

  const adaptive = `<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/wx_surface_backup" />
    <foreground android:drawable="@drawable/ic_launcher_foreground_backup" />
</adaptive-icon>
`;
  const adaptivePath = path.join(resRoot, "mipmap-anydpi-v26/ic_launcher_backup.xml");
  writeFileSync(adaptivePath, adaptive);
  backupResFiles.push(adaptivePath);

  const densities = [
    ["mipmap-mdpi", 48],
    ["mipmap-hdpi", 72],
    ["mipmap-xhdpi", 96],
    ["mipmap-xxhdpi", 144],
    ["mipmap-xxxhdpi", 192],
  ];
  for (const [folder, size] of densities) {
    const dir = path.join(resRoot, folder);
    mkdirSync(dir, { recursive: true });
    const pngPath = path.join(dir, "ic_launcher_backup.png");
    writeFileSync(pngPath, encodePng(size, size, renderBackupMark(size)));
    backupResFiles.push(pngPath);
  }
}

function patchGradle(originalGradle, storePass) {
  const signingHeader = `import java.util.Properties
import java.io.FileInputStream

val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

`;
  const releaseRe =
    /    buildTypes \{\r?\n        release \{\r?\n            \/\/ TODO: Add your own signing config for the release build\.\r?\n            \/\/ Signing with the debug keys for now, so `flutter run --release` works\.\r?\n            signingConfig = signingConfigs\.getByName\("debug"\)\r?\n        \}\r?\n    \}/;
  const releaseNew = `    signingConfigs {
        create("backupRelease") {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = file(keystoreProperties["storeFile"] as String)
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("backupRelease")
        }
    }`;
  let g = originalGradle.replace(
    /applicationId = "cn\.wenxiang\.wenxiang"/,
    `applicationId = "${BACKUP_APP_ID}"`,
  );
  if (!releaseRe.test(g)) throw new Error("build.gradle.kts release 块不匹配");
  g = g.replace(releaseRe, releaseNew);
  if (!g.includes("keystorePropertiesFile")) g = signingHeader + g;
  return g;
}

function patchColors(text) {
  if (text.includes("wx_surface_backup")) return text;
  return text.replace(
    "</resources>",
    '    <color name="wx_surface_backup">#243028</color>\n</resources>',
  );
}

function patchManifest(text) {
  return text
    .replace(/android:label="问象"/, `android:label="${BACKUP_LABEL}"`)
    .replace(/android:icon="@mipmap\/ic_launcher"/, 'android:icon="@mipmap/ic_launcher_backup"');
}

function main() {
  const { name, build } = parseVersion(readFileSync(pubspecFile, "utf8"));
  const tag = `v${name}-${build}`;
  const apkName = `问象-backup-${tag}.apk`;
  const staticDir = path.join(process.env.USERPROFILE || "", "wenxiang", "static");
  const dest = path.join(staticDir, apkName);
  const apkSrc = path.join(root, "app", "build", "app", "outputs", "flutter-apk", "app-release.apk");

  const envFile = path.join(root, ".env");
  if (!existsSync(envFile)) {
    console.error("[build-android-backup] 缺少 .env");
    process.exit(1);
  }

  snapshot(gradleFile);
  snapshot(manifestFile);
  snapshot(colorsFile);

  const storePass = randomBytes(12).toString("base64url");
  mkdirSync(tempDir, { recursive: true });
  const keytool = "C:\\Program Files\\Microsoft\\jdk-17.0.19.10-hotspot\\bin\\keytool.exe";
  const kt = spawnSync(
    keytool,
    [
      "-genkeypair",
      "-v",
      "-keystore",
      keystore,
      "-alias",
      "backup",
      "-keyalg",
      "RSA",
      "-keysize",
      "2048",
      "-validity",
      "365",
      "-storepass",
      storePass,
      "-keypass",
      storePass,
      "-dname",
      "CN=Wenxiang Backup, OU=Temp, O=Wenxiang, L=Hangzhou, ST=ZJ, C=CN",
    ],
    { stdio: "inherit" },
  );
  if (kt.status !== 0) {
    restoreAll();
    process.exit(kt.status || 1);
  }

  writeFileSync(
    keyPropsFile,
    `storePassword=${storePass}\nkeyPassword=${storePass}\nkeyAlias=backup\nstoreFile=${keystore.replace(/\\/g, "/")}\n`,
  );

  try {
    writeBackupResources();
    writeFileSync(colorsFile, patchColors(originals.get(colorsFile)));
    writeFileSync(manifestFile, patchManifest(originals.get(manifestFile)));
    writeFileSync(gradleFile, patchGradle(originals.get(gradleFile), storePass));

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
      build,
      "--dart-define-from-file=../.env",
      `--dart-define=WENXIANG_APP_LABEL=${BACKUP_LABEL}`,
      "--dart-define=WENXIANG_BACKUP=true",
    ];
    console.log(`[build-android-backup] package=${BACKUP_APP_ID} label=${BACKUP_LABEL}`);
    console.log(`[build-android-backup] 输出：${dest}`);
    const built = spawnSync(flutterBat, flutterArgs, {
      cwd: path.join(root, "app"),
      stdio: "inherit",
      shell: true,
    });
    if (built.status !== 0) {
      restoreAll();
      process.exit(built.status || 1);
    }
    if (!existsSync(apkSrc)) {
      restoreAll();
      console.error("[build-android-backup] 找不到 APK");
      process.exit(1);
    }
    mkdirSync(staticDir, { recursive: true });
    copyFileSync(apkSrc, dest);
    const st = statSync(dest);
    console.log(`[build-android-backup] OK → ${dest} (${st.size} bytes)`);
  } finally {
    restoreAll();
  }
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) main();
