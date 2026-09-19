import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/persist/book_reader_prefs.dart';

void main() {
  test('reader settings persist roundtrip', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = BookReaderPrefs(prefs);
    const settings = ReaderSettings(
      theme: ReaderThemeMode.sepia,
      fontSize: 22,
      lineHeight: 1.9,
      horizontalPadding: 28,
      navMode: ReaderNavMode.scroll,
    );
    await store.save(settings);
    final loaded = store.load();
    expect(loaded.theme, ReaderThemeMode.sepia);
    expect(loaded.fontSize, 22);
    expect(loaded.navMode, ReaderNavMode.scroll);
  });

  test('reader chrome fade matches paper in every theme', () {
    for (final mode in ReaderThemeMode.values) {
      final palette = ReaderPalette.forMode(mode);
      expect(palette.chromeFade, palette.paper);
    }
  });
}
