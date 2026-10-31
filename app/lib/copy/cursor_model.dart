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
  static const auto = CursorModelChoice(
    id: 'auto',
    label: 'Auto',
    blurb: '由 Cursor 自己选模型。',
  );
  static const opus55High = CursorModelChoice(
    id: 'claude-opus-5-5-high',
    label: 'Claude Opus 5.5 High',
    blurb: 'Anthropic，适合难一点的推理。',
  );
  static const fable51Thinking = CursorModelChoice(
    id: 'claude-fable-5-1-thinking-high',
    label: 'Claude Fable 5.1 Thinking',
    blurb: 'Anthropic 新系列；不保证零数据留存。',
  );
  static const sonnet55High = CursorModelChoice(
    id: 'claude-sonnet-5-5-high',
    label: 'Claude Sonnet 5.5 High',
    blurb: 'Anthropic，比 Opus 更轻。',
  );
  static const haiku55 = CursorModelChoice(
    id: 'claude-haiku-5-5-thinking-high',
    label: 'Claude Haiku 5.5 High',
    blurb: 'Anthropic 最轻的一档，偏快。',
  );
  static const gpt56SolHigh = CursorModelChoice(
    id: 'gpt-5.6-sol-high',
    label: 'GPT-5.6 Sol High',
    blurb: 'OpenAI 当前主力。',
  );
  static const gpt56TerraHigh = CursorModelChoice(
    id: 'gpt-5.6-terra-high',
    label: 'GPT-5.6 Terra High',
    blurb: 'OpenAI 5.6 的 Terra 版本。',
  );
  static const gpt56LunaHigh = CursorModelChoice(
    id: 'gpt-5.6-luna-high',
    label: 'GPT-5.6 Luna High',
    blurb: 'OpenAI 5.6 的 Luna 版本。',
  );
  static const codex53High = CursorModelChoice(
    id: 'gpt-5.3-codex-high',
    label: 'Codex 5.3 High',
    blurb: 'OpenAI，偏写代码。',
  );
  static const gemini4ArgonHigh = CursorModelChoice(
    id: 'gemini-4-argon-high',
    label: 'Gemini 4 Argon High',
    blurb: 'Google 新一代。',
  );
  static const gemini38Flash = CursorModelChoice(
    id: 'gemini-3.8-flash-high',
    label: 'Gemini 3.8 Flash',
    blurb: 'Google，偏快。',
  );
  static const museWonderHigh = CursorModelChoice(
    id: 'muse-wonder-1.0-high',
    label: 'Muse Wonder High',
    blurb: 'Muse 系列，可以试试。',
  );
  static const museSpark13 = CursorModelChoice(
    id: 'muse-spark-1.3-high',
    label: 'Muse Spark 1.3',
    blurb: 'Muse 系列，更轻一点。',
  );
  static const kimiK3High = CursorModelChoice(
    id: 'kimi-k3-high',
    label: 'Kimi K3 High',
    blurb: 'Moonshot，中文任务可以试。',
  );
  static const glm52 = CursorModelChoice(
    id: 'glm-5.2-high',
    label: 'GLM 5.2',
    blurb: '智谱，中文任务可以试。',
  );
  static const deepseekV41Flash = CursorModelChoice(
    id: 'deepseek-v41-flash-1017-high',
    label: 'DeepSeek V4.1 Flash',
    blurb: 'DeepSeek，偏快。',
  );

  static const values = <CursorModelChoice>[
    grokHighFast,
    grokExtraHighFast,
    grokMediumFast,
    grokHigh,
    composerFast,
    composer,
    auto,
    opus55High,
    fable51Thinking,
    sonnet55High,
    haiku55,
    gpt56SolHigh,
    gpt56TerraHigh,
    gpt56LunaHigh,
    codex53High,
    gemini4ArgonHigh,
    gemini38Flash,
    museWonderHigh,
    museSpark13,
    kimiK3High,
    glm52,
    deepseekV41Flash,
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
