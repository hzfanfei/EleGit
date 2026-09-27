/// Cursor ACP model ids the phone can switch in 设置.
enum CursorModelChoice {
  composerFast,
  grokHighFast,
}

const kDefaultCursorModel = CursorModelChoice.grokHighFast;

const kCursorModelComposerFast = 'composer-2.5-fast';
const kCursorModelGrokHighFast = 'grok-4.7-high-fast';

CursorModelChoice parseCursorModelChoice(String? raw) {
  switch (raw?.trim()) {
    case kCursorModelComposerFast:
      return CursorModelChoice.composerFast;
    case kCursorModelGrokHighFast:
    default:
      return CursorModelChoice.grokHighFast;
  }
}

String cursorModelChoiceId(CursorModelChoice choice) {
  switch (choice) {
    case CursorModelChoice.composerFast:
      return kCursorModelComposerFast;
    case CursorModelChoice.grokHighFast:
      return kCursorModelGrokHighFast;
  }
}

String cursorModelChoiceLabel(CursorModelChoice choice) {
  switch (choice) {
    case CursorModelChoice.composerFast:
      return 'Composer 2.5 Fast';
    case CursorModelChoice.grokHighFast:
      return 'Grok 4.7 High Fast';
  }
}

String cursorModelChoiceBlurb(CursorModelChoice choice) {
  switch (choice) {
    case CursorModelChoice.composerFast:
      return '改代码更快开始，思考更短。';
    case CursorModelChoice.grokHighFast:
      return '先想清楚再改，适合难一点的任务。';
  }
}
