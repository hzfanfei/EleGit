import 'cosyvoice_tts_voices.dart';
import 'volc_tts_voices.dart';
import 'xiaomi_tts_voices.dart';

class TtsVoiceOption {
  const TtsVoiceOption({
    required this.id,
    required this.name,
    required this.scene,
  });

  final String id;
  final String name;
  final String scene;

  factory TtsVoiceOption.fromJson(Map<String, dynamic> json) {
    return TtsVoiceOption(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? json['id'] ?? '').toString(),
      scene: (json['scene'] ?? '').toString(),
    );
  }
}

enum VoiceStackChoice { local, volc, xiaomi }

VoiceStackChoice parseVoiceStack(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'local':
      return VoiceStackChoice.local;
    case 'xiaomi':
      return VoiceStackChoice.xiaomi;
    default:
      return VoiceStackChoice.volc;
  }
}

String voiceStackId(VoiceStackChoice choice) {
  switch (choice) {
    case VoiceStackChoice.local:
      return 'local';
    case VoiceStackChoice.xiaomi:
      return 'xiaomi';
    case VoiceStackChoice.volc:
      return 'volc';
  }
}

String voiceStackLabel(VoiceStackChoice choice) {
  switch (choice) {
    case VoiceStackChoice.local:
      return '本地';
    case VoiceStackChoice.xiaomi:
      return '小米';
    case VoiceStackChoice.volc:
      return '火山';
  }
}

String voiceStackBlurb(VoiceStackChoice choice) {
  switch (choice) {
    case VoiceStackChoice.local:
      return 'FunASR 识别，CosyVoice 合成。';
    case VoiceStackChoice.xiaomi:
      return '小米识别，小米合成。';
    case VoiceStackChoice.volc:
      return '火山识别，火山合成。';
  }
}

class VoiceServiceProfile {
  const VoiceServiceProfile({
    this.ready = false,
    this.hint = '',
    this.voiceStack = '',
    this.ttsProvider = 'volc',
    this.ttsEngine = 'volc',
    this.asrProvider = 'volc',
    this.asrEngine = 'volc',
    this.ttsVoice = kDefaultVolcTtsVoice,
    this.voices = const [],
  });

  final bool ready;
  final String hint;
  final String voiceStack;
  final String ttsProvider;
  final String ttsEngine;
  final String asrProvider;
  final String asrEngine;
  final String ttsVoice;
  final List<TtsVoiceOption> voices;

  bool get usesCosyvoiceTts => ttsProvider == 'cosyvoice';

  bool get usesXiaomiTts => ttsProvider == 'xiaomi';

  String get activeVoiceStack {
    if (voiceStack == 'local' || voiceStack == 'volc' || voiceStack == 'xiaomi') return voiceStack;
    if (ttsProvider == 'xiaomi' && asrProvider == 'xiaomi') return 'xiaomi';
    if (ttsProvider == 'cosyvoice' && asrProvider == 'funasr') return 'local';
    return 'volc';
  }

  factory VoiceServiceProfile.fromStatusJson(Map<String, dynamic>? voice) {
    final map = voice ?? {};
    final rawVoices = map['voices'];
    final choices = rawVoices is List
        ? rawVoices
            .whereType<Map>()
            .map((e) => TtsVoiceOption.fromJson(Map<String, dynamic>.from(e)))
            .where((v) => v.id.isNotEmpty)
            .toList()
        : <TtsVoiceOption>[];
    final ttsProvider = (map['ttsProvider'] ?? 'volc').toString();
    final defaultVoice = ttsProvider == 'cosyvoice'
        ? kDefaultCosyvoiceTtsVoice
        : ttsProvider == 'xiaomi'
            ? kDefaultXiaomiTtsVoice
            : kDefaultVolcTtsVoice;
    return VoiceServiceProfile(
      ready: map['ready'] == true,
      hint: (map['hint'] ?? '').toString(),
      voiceStack: (map['voiceStack'] ?? '').toString(),
      ttsProvider: ttsProvider,
      ttsEngine: (map['ttsEngine'] ?? 'volc').toString(),
      asrProvider: (map['asrProvider'] ?? 'volc').toString(),
      asrEngine: (map['asrEngine'] ?? 'volc').toString(),
      ttsVoice: (map['ttsVoice'] ?? defaultVoice).toString(),
      voices: choices,
    );
  }

  TtsVoiceOption resolveVoice(String? raw) {
    final id = (raw ?? '').trim();
    if (id.isEmpty) return _fallbackVoice();
    for (final voice in voices) {
      if (voice.id == id) return voice;
    }
    if (usesCosyvoiceTts) {
      final local = resolveCosyvoiceTtsVoice(id);
      return TtsVoiceOption(id: local.id, name: local.name, scene: local.scene);
    }
    if (usesXiaomiTts) {
      final xiaomi = resolveXiaomiTtsVoice(id);
      return TtsVoiceOption(id: xiaomi.id, name: xiaomi.name, scene: xiaomi.scene);
    }
    final volc = resolveVolcTtsVoice(id);
    return TtsVoiceOption(id: volc.id, name: volc.name, scene: volc.scene);
  }

  TtsVoiceOption _fallbackVoice() {
    if (voices.isNotEmpty) {
      for (final voice in voices) {
        if (voice.id == ttsVoice) return voice;
      }
      return voices.first;
    }
    if (usesCosyvoiceTts) {
      final v = resolveCosyvoiceTtsVoice(ttsVoice);
      return TtsVoiceOption(id: v.id, name: v.name, scene: v.scene);
    }
    if (usesXiaomiTts) {
      final v = resolveXiaomiTtsVoice(ttsVoice);
      return TtsVoiceOption(id: v.id, name: v.name, scene: v.scene);
    }
    final v = resolveVolcTtsVoice(ttsVoice);
    return TtsVoiceOption(id: v.id, name: v.name, scene: v.scene);
  }

  List<MapEntry<String, List<TtsVoiceOption>>> voiceGroups() {
    final groups = <String, List<TtsVoiceOption>>{};
    for (final voice in voices) {
      final key = voice.scene.isNotEmpty ? voice.scene : '音色';
      groups.putIfAbsent(key, () => []).add(voice);
    }
    if (groups.isEmpty && usesXiaomiTts) {
      for (final voice in kXiaomiTtsVoices) {
        groups.putIfAbsent(voice.scene, () => []).add(
              TtsVoiceOption(id: voice.id, name: voice.name, scene: voice.scene),
            );
      }
    }
    if (groups.isEmpty && usesCosyvoiceTts) {
      for (final voice in kCosyvoiceTtsVoices) {
        groups.putIfAbsent(voice.scene, () => []).add(
              TtsVoiceOption(id: voice.id, name: voice.name, scene: voice.scene),
            );
      }
    }
    if (groups.isEmpty) {
      for (final voice in kVolcTtsVoices) {
        groups.putIfAbsent(voice.scene, () => []).add(
              TtsVoiceOption(id: voice.id, name: voice.name, scene: voice.scene),
            );
      }
    }
    return groups.entries.toList();
  }
}

String voiceEngineSummary(VoiceServiceProfile profile) {
  if (profile.usesXiaomiTts) return '小米合成 · 小米识别';
  final tts = profile.ttsEngine == 'Fun-CosyVoice3' ? 'CosyVoice3 本地' : '火山合成';
  final asr = profile.asrEngine.contains('FunASR') ? 'FunASR 本地' : '火山识别';
  return '$tts · $asr';
}
