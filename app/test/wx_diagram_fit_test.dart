import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/utils/wx_diagram_fit.dart';

void main() {
  test('diagram uses column width minus side gutters and keeps aspect', () {
    final wide = fitDiagramBox(maxWidth: 360, pixelWidth: 360, pixelHeight: 200);
    expect(wide.width, 360 - diagramSideGutter * 2);
    expect(wide.height, closeTo(wide.width * 200 / 360, 0.01));

    final tall = fitDiagramBox(maxWidth: 360, pixelWidth: 728, pixelHeight: 1620);
    expect(tall.width, 360 - diagramSideGutter * 2);
    expect(tall.height, greaterThan(480));
    expect(tall.width / tall.height, closeTo(728 / 1620, 0.001));
  });

  test('narrow column keeps the full width when gutters would crush it', () {
    final box = fitDiagramBox(maxWidth: 140, pixelWidth: 100, pixelHeight: 200);
    expect(box.width, 140);
    expect(box.height, closeTo(280, 0.01));
  });

  test('reads PNG and WebP sizes from headers', () {
    final png = Uint8List(24);
    png[0] = 0x89;
    png[1] = 0x50;
    png[2] = 0x4e;
    png[3] = 0x47;
    png[16] = 0;
    png[17] = 0;
    png[18] = 1;
    png[19] = 0x2c;
    png[20] = 0;
    png[21] = 0;
    png[22] = 2;
    png[23] = 0xd4;
    expect(readRasterSize(png), const RasterSize(300, 724));

    final webp = Uint8List(30);
    void put(int at, String text) {
      for (var i = 0; i < text.length; i++) {
        webp[at + i] = text.codeUnitAt(i);
      }
    }

    put(0, 'RIFF');
    put(8, 'WEBP');
    put(12, 'VP8X');
    webp[16] = 10;
    webp[24] = 727 & 0xff;
    webp[25] = (727 >> 8) & 0xff;
    webp[26] = 0;
    webp[27] = 1619 & 0xff;
    webp[28] = (1619 >> 8) & 0xff;
    webp[29] = 0;
    expect(readRasterSize(webp), const RasterSize(728, 1620));
  });

  test('reads svg viewBox size', () {
    const svg = '<svg viewBox="0 0 364.5 810" xmlns="http://www.w3.org/2000/svg"></svg>';
    expect(readSvgViewBoxSize(svg), const RasterSize(365, 810));
  });
}
