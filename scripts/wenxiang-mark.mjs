import { deflateSync } from "node:zlib";

export const GRAPHITE = [0x16, 0x18, 0x1c, 0xff];
export const CLAY = [0xc9, 0x84, 0x5a, 0xff];
export const MUTED = [0x9a, 0x95, 0x8c, 0xff];

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

export function encodePng(width, height, rgba) {
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

function fill(rgba, color) {
  for (let i = 0; i < rgba.length; i += 4) {
    rgba[i] = color[0];
    rgba[i + 1] = color[1];
    rgba[i + 2] = color[2];
    rgba[i + 3] = color[3];
  }
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

function circleCoverage(px, py, cx, cy, r) {
  const d = Math.hypot(px - cx, py - cy) - r;
  if (d >= 1) return 0;
  if (d <= -1) return 1;
  return 1 - (d + 1) / 2;
}

function paintShape(rgba, size, coverageAt, color) {
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const a = coverageAt(x + 0.5, y + 0.5);
      if (a > 0) blend(rgba, (y * size + x) * 4, color, a);
    }
  }
}

/** Clay ask-rail + muted form-dot on graphite — same mark as WxMark. */
export function renderMark(size, { maskable = false } = {}) {
  const rgba = Buffer.alloc(size * size * 4);
  fill(rgba, GRAPHITE);
  const inset = maskable ? 0.22 : 0.16;
  const x0 = size * inset;
  const y0 = size * inset;
  const inner = size * (1 - inset * 2);
  const barW = Math.max(2.2, inner * 0.09);
  const barX = x0 + inner * 0.30;
  const barY = y0 + inner * 0.20;
  const barH = inner * 0.60;
  const barR = barW / 2;
  const dotR = Math.max(2.4, inner * 0.085);
  const dotX = x0 + inner * 0.70;
  const dotY = y0 + inner * 0.34;
  paintShape(
    rgba,
    size,
    (px, py) => roundedRectCoverage(px, py, barX, barY, barW, barH, barR),
    CLAY,
  );
  paintShape(rgba, size, (px, py) => circleCoverage(px, py, dotX, dotY, dotR), MUTED);
  return rgba;
}

export function pngMark(size, opts) {
  return encodePng(size, size, renderMark(size, opts));
}

export function encodeIco(images) {
  const count = images.length;
  const header = Buffer.alloc(6 + 16 * count);
  header.writeUInt16LE(0, 0);
  header.writeUInt16LE(1, 2);
  header.writeUInt16LE(count, 4);
  let offset = header.length;
  const parts = [header];
  images.forEach((img, i) => {
    const entry = 6 + i * 16;
    header[entry] = img.size >= 256 ? 0 : img.size;
    header[entry + 1] = img.size >= 256 ? 0 : img.size;
    header.writeUInt32LE(img.buf.length, entry + 8);
    header.writeUInt32LE(offset, entry + 12);
    offset += img.buf.length;
    parts.push(img.buf);
  });
  return Buffer.concat(parts);
}

function near(r, g, b, color, tol = 28) {
  return Math.abs(r - color[0]) <= tol && Math.abs(g - color[1]) <= tol && Math.abs(b - color[2]) <= tol;
}

export function sampleMark(size) {
  const rgba = renderMark(size);
  const mid = (Math.floor(size / 2) * size + Math.floor(size / 2)) * 4;
  const center = [rgba[mid], rgba[mid + 1], rgba[mid + 2], rgba[mid + 3]];
  let hasClay = false;
  let hasFlutterBlue = false;
  for (let i = 0; i < rgba.length; i += 4) {
    const r = rgba[i];
    const g = rgba[i + 1];
    const b = rgba[i + 2];
    if (near(r, g, b, CLAY)) hasClay = true;
    if (g > 160 && b > 200 && r < 130) hasFlutterBlue = true;
  }
  return { center, hasClay, hasFlutterBlue };
}
