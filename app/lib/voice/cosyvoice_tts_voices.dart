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

const kCosyvoiceTtsVoices = <CosyvoiceTtsVoice>[
  CosyvoiceTtsVoice(
    id: 'wenxiang_default',
    name: '问象默认',
    scene: 'Fun-CosyVoice3 · 本地',
  ),
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
