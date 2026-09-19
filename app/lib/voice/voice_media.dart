import 'dart:typed_data';

abstract class VoiceMedia {
  Future<bool> requestMic();
  Stream<Uint8List> startMic();
  Future<void> stopMic();
  Future<void> playPcm(
    Uint8List pcm, {
    int sampleRate = 24000,
    String format = 'pcm',
    String codec = 'raw',
  });
  Future<void> stopPlayback();

  /// No-op when nothing is playing; waits until queued playback finishes.
  Future<void> waitForPlaybackQueue() async {}

  void dispose();
}

/// Boost quiet 16-bit LE PCM before playback. [gain] 1.0 = unchanged; clamps to int16.
Uint8List amplifyPcm16(Uint8List pcm, {double gain = 1.35}) {
  if (gain == 1.0 || pcm.length < 2) return pcm;
  final out = Uint8List.fromList(pcm);
  final view = ByteData.view(out.buffer, out.offsetInBytes, out.lengthInBytes);
  for (var i = 0; i + 1 < out.length; i += 2) {
    var sample = view.getInt16(i, Endian.little);
    sample = (sample * gain).round();
    if (sample > 32767) sample = 32767;
    if (sample < -32768) sample = -32768;
    view.setInt16(i, sample, Endian.little);
  }
  return out;
}

class FakeVoiceMedia implements VoiceMedia {
  FakeVoiceMedia({this.micGranted = true});

  bool micGranted;
  int requestCalls = 0;
  int startCalls = 0;
  int stopMicCalls = 0;
  int stopPlayCalls = 0;
  final List<Uint8List> played = [];

  @override
  Future<bool> requestMic() async {
    requestCalls += 1;
    return micGranted;
  }

  @override
  Stream<Uint8List> startMic() {
    startCalls += 1;
    return const Stream.empty();
  }

  @override
  Future<void> stopMic() async {
    stopMicCalls += 1;
  }

  @override
  Future<void> playPcm(
    Uint8List pcm, {
    int sampleRate = 24000,
    String format = 'pcm',
    String codec = 'raw',
  }) async {
    played.add(pcm);
  }

  @override
  Future<void> stopPlayback() async {
    stopPlayCalls += 1;
  }

  @override
  Future<void> waitForPlaybackQueue() async {}

  @override
  void dispose() {}
}

Uint8List pcm16ToWav(Uint8List pcm, {int sampleRate = 24000, int channels = 1}) {
  final byteRate = sampleRate * channels * 2;
  final data = ByteData(44 + pcm.length);
  final bytes = data.buffer.asUint8List();
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes[offset + i] = text.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, byteRate, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, pcm.length, Endian.little);
  bytes.setRange(44, 44 + pcm.length, pcm);
  return bytes;
}
