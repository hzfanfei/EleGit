import { mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { encodeIco, pngMark } from "./wenxiang-mark.mjs";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");

function write(rel, buf) {
  const dest = path.join(root, rel);
  mkdirSync(path.dirname(dest), { recursive: true });
  writeFileSync(dest, buf);
  console.log(rel, buf.length);
}

const ios = [
  ["Icon-App-20x20@1x.png", 20],
  ["Icon-App-20x20@2x.png", 40],
  ["Icon-App-20x20@3x.png", 60],
  ["Icon-App-29x29@1x.png", 29],
  ["Icon-App-29x29@2x.png", 58],
  ["Icon-App-29x29@3x.png", 87],
  ["Icon-App-40x40@1x.png", 40],
  ["Icon-App-40x40@2x.png", 80],
  ["Icon-App-40x40@3x.png", 120],
  ["Icon-App-60x60@2x.png", 120],
  ["Icon-App-60x60@3x.png", 180],
  ["Icon-App-76x76@1x.png", 76],
  ["Icon-App-76x76@2x.png", 152],
  ["Icon-App-83.5x83.5@2x.png", 167],
  ["Icon-App-1024x1024@1x.png", 1024],
];

for (const [name, size] of ios) {
  write(`app/ios/Runner/Assets.xcassets/AppIcon.appiconset/${name}`, pngMark(size));
}

const mac = [
  ["app_icon_16.png", 16],
  ["app_icon_32.png", 32],
  ["app_icon_64.png", 64],
  ["app_icon_128.png", 128],
  ["app_icon_256.png", 256],
  ["app_icon_512.png", 512],
  ["app_icon_1024.png", 1024],
];
for (const [name, size] of mac) {
  write(`app/macos/Runner/Assets.xcassets/AppIcon.appiconset/${name}`, pngMark(size));
}

const android = [
  ["mipmap-mdpi/ic_launcher.png", 48],
  ["mipmap-hdpi/ic_launcher.png", 72],
  ["mipmap-xhdpi/ic_launcher.png", 96],
  ["mipmap-xxhdpi/ic_launcher.png", 144],
  ["mipmap-xxxhdpi/ic_launcher.png", 192],
];
for (const [name, size] of android) {
  write(`app/android/app/src/main/res/${name}`, pngMark(size));
}

write("app/web/favicon.png", pngMark(16));
write("app/web/icons/Icon-192.png", pngMark(192));
write("app/web/icons/Icon-512.png", pngMark(512));
write("app/web/icons/Icon-maskable-192.png", pngMark(192, { maskable: true }));
write("app/web/icons/Icon-maskable-512.png", pngMark(512, { maskable: true }));

const icoSizes = [16, 32, 48, 256];
write(
  "app/windows/runner/resources/app_icon.ico",
  encodeIco(icoSizes.map((size) => ({ size, buf: pngMark(size) }))),
);

write("app/linux/runner/resources/wenxiang.png", pngMark(256));
