/// Cursor ACP model ids the phone can switch in 设置.
/// Ids match `agent --list-models` on this machine. One practical variant per family.
class CursorModelChoice {
  const CursorModelChoice({
    required this.id,
    required this.label,
    required this.blurb,
  });

  final String id;
  final String label;
  final String blurb;

  static const grokHighFast = CursorModelChoice(
    id: 'grok-4.7-high-fast',
    label: 'Grok 4.7 High Fast',
    blurb: '先想清楚再改，适合难一点的任务。',
  );
  static const grokExtraHighFast = CursorModelChoice(
    id: 'grok-4.7-xhigh-fast',
    label: 'Grok 4.7 Extra High Fast',
    blurb: '想得更久，适合更难的任务。',
  );
  static const grokMediumFast = CursorModelChoice(
    id: 'grok-4.7-medium-fast',
    label: 'Grok 4.7 Medium Fast',
    blurb: '思考更短，日常改动更快。',
  );
  static const grokHigh = CursorModelChoice(
    id: 'grok-4.7-high',
    label: 'Grok 4.7 High',
    blurb: '同样先想清楚，用量更省。',
  );
  static const composerFast = CursorModelChoice(
    id: 'composer-2.5-fast',
    label: 'Composer 2.5 Fast',
    blurb: '改代码更快开始，思考更短。',
  );
  static const composer = CursorModelChoice(
    id: 'composer-2.5',
    label: 'Composer 2.5',
    blurb: '同样改代码，用量更省。',
  );
  static const grok46Fast = CursorModelChoice(
    id: 'cursor-grok-4.6-high-fast',
    label: 'Grok 4.6 Fast',
    blurb: '上一代，适合日常改动。',
  );
  static const grok45Fast = CursorModelChoice(
    id: 'cursor-grok-4.5-high-fast',
    label: 'Grok 4.5 Fast',
    blurb: '更早一代，适合轻一点的改动。',
  );
  static const auto = CursorModelChoice(
    id: 'auto',
    label: 'Auto',
    blurb: '由 Cursor 自己选模型。',
  );
  static const gpt55High = CursorModelChoice(
    id: 'gpt-5.5-high',
    label: 'GPT-5.5 High',
    blurb: 'OpenAI，适合长一点的任务。',
  );
  static const gpt56SolHigh = CursorModelChoice(
    id: 'gpt-5.6-sol-high',
    label: 'GPT-5.6 Sol High',
    blurb: 'OpenAI 当前主力。',
  );
  static const codex53High = CursorModelChoice(
    id: 'gpt-5.3-codex-high',
    label: 'Codex 5.3 High',
    blurb: 'OpenAI，偏写代码。',
  );
  static const opus55High = CursorModelChoice(
    id: 'claude-opus-5-5-high',
    label: 'Claude Opus 5.5 High',
    blurb: 'Anthropic，适合难一点的推理。',
  );
  static const sonnet5Thinking = CursorModelChoice(
    id: 'claude-sonnet-5-thinking-high',
    label: 'Claude Sonnet 5 Thinking',
    blurb: 'Anthropic，比 Opus 更轻。',
  );
  static const gemini38Flash = CursorModelChoice(
    id: 'gemini-3.8-flash-high',
    label: 'Gemini 3.8 Flash',
    blurb: 'Google，偏快。',
  );
  static const kimiK3High = CursorModelChoice(
    id: 'kimi-k3-high',
    label: 'Kimi K3 High',
    blurb: 'Moonshot，中文任务可以试。',
  );

  static const values = <CursorModelChoice>[
    grokHighFast,
    grokExtraHighFast,
    grokMediumFast,
    grokHigh,
    composerFast,
    composer,
    grok46Fast,
    grok45Fast,
    auto,
    gpt55High,
    gpt56SolHigh,
    codex53High,
    opus55High,
    sonnet5Thinking,
    gemini38Flash,
    kimiK3High,
  ];
}

const kDefaultCursorModel = CursorModelChoice.grokHighFast;

CursorModelChoice parseCursorModelChoice(String? raw) {
  final id = raw?.trim();
  for (final choice in CursorModelChoice.values) {
    if (choice.id == id) return choice;
  }
  return kDefaultCursorModel;
}

String cursorModelChoiceId(CursorModelChoice choice) => choice.id;

String cursorModelChoiceLabel(CursorModelChoice choice) => choice.label;

String cursorModelChoiceBlurb(CursorModelChoice choice) => choice.blurb;
