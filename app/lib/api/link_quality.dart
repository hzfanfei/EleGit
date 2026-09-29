/// Latency tier for the header ping indicator (game-style signal bars).
enum LinkQualityTier {
  unknown,
  offline,
  poor,
  fair,
  good,
}

class HealthProbeResult {
  const HealthProbeResult({required this.ok, this.rttMs});

  final bool ok;
  final int? rttMs;
}

LinkQualityTier linkQualityTier({required bool ok, int? rttMs}) {
  if (!ok) return LinkQualityTier.offline;
  final ms = rttMs;
  if (ms == null) return LinkQualityTier.offline;
  if (ms <= 200) return LinkQualityTier.good;
  if (ms <= 600) return LinkQualityTier.fair;
  return LinkQualityTier.poor;
}

int linkQualityFilledBars(LinkQualityTier tier) {
  switch (tier) {
    case LinkQualityTier.good:
      return 4;
    case LinkQualityTier.fair:
      return 3;
    case LinkQualityTier.poor:
      return 1;
    case LinkQualityTier.offline:
      return 0;
    case LinkQualityTier.unknown:
      return 0;
  }
}

String linkQualityTierLabel(LinkQualityTier tier) {
  switch (tier) {
    case LinkQualityTier.good:
      return '良好';
    case LinkQualityTier.fair:
      return '一般';
    case LinkQualityTier.poor:
      return '偏高';
    case LinkQualityTier.offline:
      return '断连';
    case LinkQualityTier.unknown:
      return '测量中';
  }
}

Future<HealthProbeResult> probeHealthAt(
  String root, {
  required Duration timeout,
  required String apiKey,
}) async {
  final sw = Stopwatch()..start();
  try {
    final url = root.replaceAll(RegExp(r'/$'), '');
    final res = await http
        .get(
          Uri.parse('$url/health'),
          headers: {
            'X-Wenxiang-Key': apiKey,
            'ngrok-skip-browser-warning': 'true',
          },
        )
        .timeout(timeout);
    sw.stop();
    if (res.statusCode == 200) {
      return HealthProbeResult(ok: true, rttMs: sw.elapsedMilliseconds);
    }
    return const HealthProbeResult(ok: false);
  } catch (_) {
    sw.stop();
    return const HealthProbeResult(ok: false);
  }
}
