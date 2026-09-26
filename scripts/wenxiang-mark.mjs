import { deflateSync } from "node:zlib";

/** Same ink and ochre as Wx.surface / Wx.accent. */
export const SURFACE = [0x1a, 0x17, 0x14, 0xff];
export const ACCENT = [0xa6, 0x7c, 0x52, 0xff];

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

function paintShape(rgba, size, coverageAt, color) {
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const a = coverageAt(x + 0.5, y + 0.5);
      if (a > 0) blend(rgba, (y * size + x) * 4, color, a);
    }
  }
}

/** Square seal: ochre frame and center stroke on ink. Same geometry as WxMark. */
export function renderMark(size, { maskable = false } = {}) {
  const rgba = Buffer.alloc(size * size * 4);
  fill(rgba, SURFACE);
  const inset = maskable ? 0.24 : 0.16;
  const x0 = size * inset;
  const y0 = size * inset;
  const inner = size * (1 - inset * 2);
  const radius = inner * 0.08;
  const stroke = Math.max(1, inner * 0.07);
  paintShape(
    rgba,
    size,
    (px, py) => {
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
      return Math.max(0, outer - hole);
    },
    ACCENT,
  );
  const barW = Math.max(1.6, inner * 0.075);
  const barH = inner * 0.48;
  const barX = x0 + (inner - barW) / 2;
  const barY = y0 + inner * 0.26;
  const barR = Math.min(barW / 2, 0.8);
  paintShape(
    rgba,
    size,
    (px, py) => roundedRectCoverage(px, py, barX, barY, barW, barH, barR),
    ACCENT,
  );
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
  const at = (x, y) => {
    const i = (y * size + x) * 4;
    return [rgba[i], rgba[i + 1], rgba[i + 2], rgba[i + 3]];
  };
  const mid = Math.floor(size / 2);
  const center = at(mid, mid);
  let hasAccent = false;
  let hasFlutterBlue = false;
  for (let i = 0; i < rgba.length; i += 4) {
    const r = rgba[i];
    const g = rgba[i + 1];
    const b = rgba[i + 2];
    if (near(r, g, b, ACCENT)) hasAccent = true;
    if (g > 160 && b > 200 && r < 130) hasFlutterBlue = true;
  }
  return { center, corner: at(1, 1), hasAccent, hasFlutterBlue };
}
