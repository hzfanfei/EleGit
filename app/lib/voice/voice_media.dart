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
    String segmentCaption = '',
    void Function()? onPlaybackStart,
  });
  Future<void> stopPlayback();

  /// No-op when nothing is playing; waits until queued playback finishes.
  Future<void> waitForPlaybackQueue() async {}

  void dispose();
}

/// Boost quiet 16-bit LE PCM before playback. Clamps to int16.
///
/// By default peak-normalizes toward [targetPeak] of full scale (good for quiet TTS).
/// Pass [gain] to force a fixed multiplier (tests / overrides).
Uint8List amplifyPcm16(
  Uint8List pcm, {
  double? gain,
  double targetPeak = 0.98,
  double minGain = 1.75,
  double maxGain = 3.5,
}) {
  if (pcm.length < 2) return pcm;
  final out = Uint8List.fromList(pcm);
  final view = ByteData.view(out.buffer, out.offsetInBytes, out.lengthInBytes);

  var peak = 1;
  for (var i = 0; i + 1 < out.length; i += 2) {
    final abs = view.getInt16(i, Endian.little).abs();
    if (abs > peak) peak = abs;
  }
  if (peak == 0) return out;

  final effectiveGain = gain ??
      (32767.0 * targetPeak / peak).clamp(minGain, maxGain).toDouble();
  if (effectiveGain == 1.0) return out;

  for (var i = 0; i + 1 < out.length; i += 2) {
    var sample = view.getInt16(i, Endian.little);
    sample = (sample * effectiveGain).round();
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
    String segmentCaption = '',
    void Function()? onPlaybackStart,
  }) async {
    onPlaybackStart?.call();
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

/// Truncate trailing byte so 16-bit PCM sample pairs are complete.
Uint8List normalizePcm16Length(Uint8List pcm) {
  if (pcm.length < 2) return Uint8List(0);
  if (pcm.length.isOdd) return Uint8List.sublistView(pcm, 0, pcm.length - 1);
  return pcm;
}

Uint8List pcm16ToWav(Uint8List pcm, {int sampleRate = 24000, int channels = 1}) {
  pcm = normalizePcm16Length(pcm);
  if (pcm.isEmpty) return Uint8List(0);
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
