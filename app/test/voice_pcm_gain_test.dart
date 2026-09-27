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

  test('amplifyPcm16 bends loud samples below full scale instead of cutting them flat', () {
    final pcm = Uint8List(6);
    final view = ByteData.view(pcm.buffer);
    view.setInt16(0, 10000, Endian.little);
    view.setInt16(2, 20000, Endian.little);
    view.setInt16(4, -24000, Endian.little);
    final out = ByteData.view(amplifyPcm16(pcm, gain: 1.75).buffer);
    expect(out.getInt16(0, Endian.little), 17500);
    final loud = out.getInt16(2, Endian.little);
    final louder = out.getInt16(4, Endian.little).abs();
    expect(loud, lessThan(32767));
    expect(louder, lessThan(32767));
    expect(louder, greaterThan(loud));
    expect(loud, greaterThan(26214));
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

  test('playbackCompleteBudget follows pcm length and stays bounded', () {
    expect(
      playbackCompleteBudget(byteLength: 24000 * 2, sampleRate: 24000),
      const Duration(milliseconds: 4000),
    );
    expect(
      playbackCompleteBudget(byteLength: 24000 * 2 * 20, sampleRate: 24000),
      const Duration(milliseconds: 22500),
    );
    expect(
      playbackCompleteBudget(byteLength: 24000 * 2 * 200, sampleRate: 24000),
      const Duration(milliseconds: 120000),
    );
    expect(
      playbackCompleteBudget(byteLength: 100, sampleRate: 24000, format: 'mp3'),
      const Duration(seconds: 20),
    );
  });

  test('normalizePcm16Length drops trailing byte', () {
    expect(normalizePcm16Length(Uint8List.fromList([1, 2, 3])).length, 2);
    expect(normalizePcm16Length(Uint8List(1)).length, 0);
  });
}
