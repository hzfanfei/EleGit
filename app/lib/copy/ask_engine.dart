/// User-facing ask backend choice (maps to companion `acpEngine` claude | cursor | codex).
enum AskEngineChoice {
  claude,
  cursor,
  codex,
}

enum AskEngineScope {
  book,
  repo,
}

const kDefaultAskEngine = AskEngineChoice.claude;

AskEngineChoice parseAskEngineChoice(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'cursor':
      return AskEngineChoice.cursor;
    case 'codex':
      return AskEngineChoice.codex;
    case 'claude':
    default:
      return AskEngineChoice.claude;
  }
}

String askEngineChoiceId(AskEngineChoice choice) {
  switch (choice) {
    case AskEngineChoice.cursor:
      return 'cursor';
    case AskEngineChoice.codex:
      return 'codex';
    case AskEngineChoice.claude:
      return 'claude';
  }
}

String askEngineScopeId(AskEngineScope scope) {
  switch (scope) {
    case AskEngineScope.book:
      return 'book';
    case AskEngineScope.repo:
      return 'repo';
  }
}

String askEngineChoiceLabel(AskEngineChoice choice) {
  switch (choice) {
    case AskEngineChoice.cursor:
      return 'Cursor';
    case AskEngineChoice.codex:
      return 'Codex';
    case AskEngineChoice.claude:
      return 'Claude Code';
  }
}

String askEngineScopeTitle(AskEngineScope scope) {
  switch (scope) {
    case AskEngineScope.book:
      return '问书';
    case AskEngineScope.repo:
      return '问象（仓库进度）';
  }
}

String askEngineChoiceBlurb(AskEngineChoice choice, AskEngineScope scope) {
  switch (scope) {
    case AskEngineScope.book:
      switch (choice) {
        case AskEngineChoice.cursor:
          return '读书问答走 Cursor 本机 Agent。';
        case AskEngineChoice.codex:
          return '读书问答走本机 Codex，只读。';
        case AskEngineChoice.claude:
          return '读书问答走 Claude Code 本机 Agent。';
      }
    case AskEngineScope.repo:
      switch (choice) {
        case AskEngineChoice.cursor:
          return '仓库聊天与 Agent 模式走 Cursor。';
        case AskEngineChoice.codex:
          return '仓库聊天与 Agent 模式走本机 Codex。';
        case AskEngineChoice.claude:
          return '仓库聊天与 Agent 模式走 Claude Code。';
      }
  }
}
