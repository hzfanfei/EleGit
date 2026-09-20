import 'volc_tts_voices.dart';

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

/// Same speaker ids as seed-tts-2.0 / cosyvoice_voices.json (Volc-derived prompts).
const kDefaultCosyvoiceTtsVoice = kDefaultVolcTtsVoice;

/// Fallback when /v1/status has not loaded yet (keep in sync with cosyvoice_voices.json).
final kCosyvoiceTtsVoices = kVolcTtsVoices
    .map(
      (v) => CosyvoiceTtsVoice(id: v.id, name: v.name, scene: v.scene),
    )
    .toList(growable: false);

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
