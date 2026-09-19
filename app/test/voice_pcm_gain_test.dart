import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/voice_media.dart';

void main() {
  test('amplifyPcm16 boosts and clamps samples', () {
    final pcm = Uint8List(4);
    final view = ByteData.view(pcm.buffer);
    view.setInt16(0, 1000, Endian.little);
    view.setInt16(2, -1000, Endian.little);
    final out = amplifyPcm16(pcm, gain: 2.0);
    final outView = ByteData.view(out.buffer);
    expect(outView.getInt16(0, Endian.little), 2000);
    expect(outView.getInt16(2, Endian.little), -2000);
  });

  test('amplifyPcm16 peak-normalizes quiet TTS', () {
    final pcm = Uint8List(4);
    final view = ByteData.view(pcm.buffer);
    view.setInt16(0, 800, Endian.little);
    view.setInt16(2, -800, Endian.little);
    final out = amplifyPcm16(pcm);
    final outView = ByteData.view(out.buffer);
    expect(outView.getInt16(0, Endian.little).abs(), greaterThan(800));
  });
}
