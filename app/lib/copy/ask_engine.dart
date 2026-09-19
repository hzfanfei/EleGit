/// User-facing ask backend choice (maps to companion `acpEngine` claude | cursor).
enum AskEngineChoice {
  claude,
  cursor,
}

const kDefaultAskEngine = AskEngineChoice.claude;

AskEngineChoice parseAskEngineChoice(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'cursor':
      return AskEngineChoice.cursor;
    case 'claude':
    default:
      return AskEngineChoice.claude;
  }
}

String askEngineChoiceId(AskEngineChoice choice) {
  switch (choice) {
    case AskEngineChoice.cursor:
      return 'cursor';
    case AskEngineChoice.claude:
      return 'claude';
  }
}

String askEngineChoiceLabel(AskEngineChoice choice) {
  switch (choice) {
    case AskEngineChoice.cursor:
      return 'Cursor';
    case AskEngineChoice.claude:
      return 'Claude Code';
  }
}

String askEngineChoiceBlurb(AskEngineChoice choice) {
  switch (choice) {
    case AskEngineChoice.cursor:
      return '使用 Cursor 本机 Agent 回答问书与仓库进度。';
    case AskEngineChoice.claude:
      return '使用 Claude Code 本机 Agent 回答问书与仓库进度。';
  }
}
