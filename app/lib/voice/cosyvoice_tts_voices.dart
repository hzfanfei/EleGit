class CosyvoiceTtsVoice {
  const CosyvoiceTtsVoice({
    required this.id,
    required this.name,
    required this.scene,
  });

  final String id;
  final String name;
  final String scene;
}

const kDefaultCosyvoiceTtsVoice = 'wenxiang_default';

/// Fallback when /v1/status has not loaded yet (keep in sync with cosyvoice_voices.json).
const kCosyvoiceTtsVoices = <CosyvoiceTtsVoice>[
  CosyvoiceTtsVoice(id: 'wenxiang_default', name: '清亮女声', scene: '中文 · 官方参考'),
  CosyvoiceTtsVoice(id: 'zh_xiaoxiao', name: '晓晓', scene: '中文 · 女声'),
  CosyvoiceTtsVoice(id: 'zh_xiaoyi', name: '晓伊', scene: '中文 · 女声'),
  CosyvoiceTtsVoice(id: 'zh_yunxi', name: '云希', scene: '中文 · 男声'),
  CosyvoiceTtsVoice(id: 'zh_yunjian', name: '云健', scene: '中文 · 男声'),
];

CosyvoiceTtsVoice resolveCosyvoiceTtsVoice(String? raw) {
  final id = (raw ?? '').trim();
  for (final voice in kCosyvoiceTtsVoices) {
    if (voice.id == id) return voice;
  }
  if (id.isNotEmpty) {
    return CosyvoiceTtsVoice(id: id, name: id, scene: 'Fun-CosyVoice3 · 本地');
  }
  return kCosyvoiceTtsVoices.first;
}
