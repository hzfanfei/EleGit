import 'package:flutter_test/flutter_test.dart';
import 'package:wenxiang/api/link_quality.dart';

void main() {
  test('tiers follow game-style ping thresholds', () {
    expect(linkQualityTier(ok: false, rttMs: 50), LinkQualityTier.offline);
    expect(linkQualityTier(ok: true, rttMs: 80), LinkQualityTier.good);
    expect(linkQualityTier(ok: true, rttMs: 200), LinkQualityTier.good);
    expect(linkQualityTier(ok: true, rttMs: 201), LinkQualityTier.fair);
    expect(linkQualityTier(ok: true, rttMs: 600), LinkQualityTier.fair);
    expect(linkQualityTier(ok: true, rttMs: 601), LinkQualityTier.poor);
  });

  test('filled bars match tier', () {
    expect(linkQualityFilledBars(LinkQualityTier.good), 4);
    expect(linkQualityFilledBars(LinkQualityTier.fair), 3);
    expect(linkQualityFilledBars(LinkQualityTier.poor), 1);
    expect(linkQualityFilledBars(LinkQualityTier.offline), 0);
  });
}
