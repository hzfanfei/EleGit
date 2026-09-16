import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { sampleMark, GRAPHITE, CLAY } from "../../scripts/wenxiang-mark.mjs";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "..");

function isPng(buf) {
  return buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4e && buf[3] === 0x47;
}

describe("问象 launcher mark", () => {
  it("paints graphite and clay, not Flutter blue", () => {
    const shot = sampleMark(64);
    assert.deepEqual(shot.center, GRAPHITE);
    assert.ok(shot.hasClay);
    assert.equal(shot.hasFlutterBlue, false);
    assert.deepEqual(CLAY, [0xc9, 0x84, 0x5a, 0xff]);
  });

  it("replaces Flutter default icons on shipped platforms", () => {
    const files = [
      "app/web/favicon.png",
      "app/web/icons/Icon-192.png",
      "app/web/icons/Icon-512.png",
      "app/web/icons/Icon-maskable-192.png",
      "app/web/icons/Icon-maskable-512.png",
      "app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png",
      "app/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png",
      "app/macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png",
      "app/windows/runner/resources/app_icon.ico",
    ];
    for (const rel of files) {
      const buf = readFileSync(path.join(root, rel));
      assert.ok(buf.length > 32, rel);
      if (rel.endsWith(".ico")) {
        assert.equal(buf[0], 0);
        assert.equal(buf[1], 0);
        assert.ok(buf[2] === 1 || buf[2] === 2);
      } else {
        assert.ok(isPng(buf), rel);
      }
    }
    const web = readFileSync(path.join(root, "app/web/icons/Icon-192.png"));
    assert.equal(web.readUInt32BE(16), 192);
    assert.equal(web[25], 6, "RGBA mark, not the RGB Flutter logo");
  });
});
