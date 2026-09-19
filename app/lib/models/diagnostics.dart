class DiagnosticsProbeResult {
  DiagnosticsProbeResult({
    required this.ok,
    required this.at,
    this.askCli,
    this.askModel,
    this.voiceTts,
    this.voiceStt,
  });

  final bool ok;
  final String at;
  final DiagnosticsStep? askCli;
  final DiagnosticsStep? askModel;
  final DiagnosticsVoiceTtsStep? voiceTts;
  final DiagnosticsVoiceSttStep? voiceStt;

  factory DiagnosticsProbeResult.fromJson(Map<String, dynamic> json) {
    return DiagnosticsProbeResult(
      ok: json['ok'] == true,
      at: (json['at'] ?? '').toString(),
      askCli: DiagnosticsStep.fromJson(json['askCli']),
      askModel: DiagnosticsStep.fromJson(json['askModel']),
      voiceTts: DiagnosticsVoiceTtsStep.fromJson(json['voiceTts']),
      voiceStt: DiagnosticsVoiceSttStep.fromJson(json['voiceStt']),
    );
  }
}

class DiagnosticsStep {
  DiagnosticsStep({
    required this.ok,
    required this.ms,
    this.error,
    this.snippet,
    this.engine,
  });

  final bool ok;
  final int ms;
  final String? error;
  final String? snippet;
  final String? engine;

  static DiagnosticsStep? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return DiagnosticsStep(
      ok: json['ok'] == true,
      ms: (json['ms'] as num?)?.toInt() ?? 0,
      error: json['error']?.toString(),
      snippet: json['snippet']?.toString(),
      engine: json['engine']?.toString(),
    );
  }
}

class DiagnosticsVoiceTtsStep {
  DiagnosticsVoiceTtsStep({
    required this.ok,
    required this.ms,
    this.error,
    this.bytes = 0,
    this.provider,
  });

  final bool ok;
  final int ms;
  final String? error;
  final int bytes;
  final String? provider;

  static DiagnosticsVoiceTtsStep? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return DiagnosticsVoiceTtsStep(
      ok: json['ok'] == true,
      ms: (json['ms'] as num?)?.toInt() ?? 0,
      error: json['error']?.toString(),
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      provider: json['provider']?.toString(),
    );
  }
}

class DiagnosticsVoiceSttStep {
  DiagnosticsVoiceSttStep({
    required this.ok,
    required this.ms,
    this.error,
    this.provider,
  });

  final bool ok;
  final int ms;
  final String? error;
  final String? provider;

  static DiagnosticsVoiceSttStep? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    return DiagnosticsVoiceSttStep(
      ok: json['ok'] == true,
      ms: (json['ms'] as num?)?.toInt() ?? 0,
      error: json['error']?.toString(),
      provider: json['provider']?.toString(),
    );
  }
}
