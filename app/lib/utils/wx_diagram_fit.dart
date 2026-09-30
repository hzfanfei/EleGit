import 'dart:typed_data';

/// Pixel size of a PNG or WebP, read from the header.
class RasterSize {
  const RasterSize(this.width, this.height);

  final int width;
  final int height;

  @override
  bool operator ==(Object other) => other is RasterSize && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);
}

/// Laid-out size of a diagram inside the chat column.
class DiagramBox {
  const DiagramBox(this.width, this.height);

  final double width;
  final double height;
}

/// Inline diagrams use two thirds of the chat column so the sides stay open.
const diagramWidthFraction = 2 / 3;

/// Two thirds of the column. Very narrow columns keep the full width.
double diagramLayoutWidth(double maxWidth) {
  final maxW = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 280.0;
  final inner = maxW * diagramWidthFraction;
  if (inner < 160) return maxW;
  return inner;
}

/// Size the picture to two thirds of the chat column and keep its aspect ratio.
/// Height follows the picture, so a tall diagram can run past one screen.
DiagramBox fitDiagramBox({
  required double maxWidth,
  required double pixelWidth,
  required double pixelHeight,
}) {
  final width = diagramLayoutWidth(maxWidth);
  if (pixelWidth <= 0 || pixelHeight <= 0) {
    return DiagramBox(width, width * 0.75);
  }
  return DiagramBox(width, width * pixelHeight / pixelWidth);
}

RasterSize? readRasterSize(Uint8List bytes) {
  final png = _pngSize(bytes);
  if (png != null) return png;
  return _webpSize(bytes);
}

/// `viewBox="minX minY width height"` from a mermaid SVG.
RasterSize? readSvgViewBoxSize(String svg) {
  final match = RegExp(
    r'viewBox\s*=\s*"\s*[-\d.]+\s+[-\d.]+\s+([\d.]+)\s+([\d.]+)\s*"',
    caseSensitive: false,
  ).firstMatch(svg);
  if (match == null) return null;
  final width = double.tryParse(match.group(1) ?? '');
  final height = double.tryParse(match.group(2) ?? '');
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return RasterSize(width.round(), height.round());
}

RasterSize? _pngSize(Uint8List bytes) {
  if (bytes.length < 24) return null;
  if (bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4e || bytes[3] != 0x47) return null;
  final width = _u32be(bytes, 16);
  final height = _u32be(bytes, 20);
  if (width <= 0 || height <= 0) return null;
  return RasterSize(width, height);
}

RasterSize? _webpSize(Uint8List bytes) {
  if (bytes.length < 16) return null;
  if (!_ascii(bytes, 0, 'RIFF') || !_ascii(bytes, 8, 'WEBP')) return null;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final tag = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = _u32le(bytes, offset + 4);
    final data = offset + 8;
    if (tag == 'VP8X' && data + 10 <= bytes.length) {
      final width = 1 + (bytes[data + 4] | (bytes[data + 5] << 8) | (bytes[data + 6] << 16));
      final height = 1 + (bytes[data + 7] | (bytes[data + 8] << 8) | (bytes[data + 9] << 16));
      if (width > 0 && height > 0) return RasterSize(width, height);
    }
    if (tag == 'VP8 ' && data + 10 <= bytes.length) {
      final start = data + 3;
      if (bytes[start] == 0x9d && bytes[start + 1] == 0x01 && bytes[start + 2] == 0x2a) {
        final width = (bytes[start + 3] | (bytes[start + 4] << 8)) & 0x3fff;
        final height = (bytes[start + 5] | (bytes[start + 6] << 8)) & 0x3fff;
        if (width > 0 && height > 0) return RasterSize(width, height);
      }
    }
    if (tag == 'VP8L' && data + 5 <= bytes.length && bytes[data] == 0x2f) {
      final bits = _u32le(bytes, data + 1);
      final width = (bits & 0x3fff) + 1;
      final height = ((bits >> 14) & 0x3fff) + 1;
      if (width > 0 && height > 0) return RasterSize(width, height);
    }
    if (size <= 0) break;
    offset = data + size + (size & 1);
  }
  return null;
}

int _u32be(Uint8List bytes, int offset) {
  return (bytes[offset] << 24) | (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
}

int _u32le(Uint8List bytes, int offset) {
  return bytes[offset] | (bytes[offset + 1] << 8) | (bytes[offset + 2] << 16) | (bytes[offset + 3] << 24);
}

bool _ascii(Uint8List bytes, int offset, String text) {
  if (offset + text.length > bytes.length) return false;
  for (var i = 0; i < text.length; i++) {
    if (bytes[offset + i] != text.codeUnitAt(i)) return false;
  }
  return true;
}
