import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/voice/audio_format.dart';

void main() {
  test('negative PCM samples and a single MPEG header are not MP3', () {
    expect(looksLikeMp3(Uint8List.fromList([255, 255, 0, 0])), false);
    final pcm = Uint8List(1000)..setAll(0, [255, 251, 144, 0]);
    expect(looksLikeMp3(pcm), false);
    expect(looksLikeMp3(Uint8List.fromList([73, 68, 51, 0])), false);
  });
  test('recognizes consecutive MPEG1 and MPEG2 Layer III frames', () {
    for (final item in [(251, 144, 417), (243, 128, 208)]) {
      final bytes = Uint8List(item.$3 * 2);
      bytes.setAll(0, [255, item.$1, item.$2, 0]);
      bytes.setAll(item.$3, [255, item.$1, item.$2, 0]);
      expect(looksLikeMp3(bytes), true);
      expect(looksLikeMp3(Uint8List.sublistView(bytes, 0, bytes.length - 1)),
          false);
    }
  });
  test('recognizes a valid ID3 header', () {
    expect(looksLikeMp3(Uint8List.fromList([73, 68, 51, 4, 0, 0, 0, 0, 0, 0])),
        true);
  });
}
