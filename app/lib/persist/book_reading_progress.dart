import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class BookReadingResume {
  const BookReadingResume({
    required this.chapterIndex,
    this.throughChapterIndex,
    this.scrollOffset = 0,
  });

  /// First chapter included in the continuous scroll stack.
  final int chapterIndex;

  /// Last chapter included (≥ [chapterIndex]); null means same as [chapterIndex].
  final int? throughChapterIndex;

  final double scrollOffset;

  int get lastChapter => throughChapterIndex ?? chapterIndex;

  Map<String, dynamic> toJson() => {
        'chapterIndex': chapterIndex,
        if (throughChapterIndex != null && throughChapterIndex != chapterIndex)
          'throughChapterIndex': throughChapterIndex,
        'scrollOffset': scrollOffset,
      };

  factory BookReadingResume.fromJson(Map<String, dynamic> json) {
    final first = (json['chapterIndex'] as num?)?.toInt() ?? 0;
    final through = (json['throughChapterIndex'] as num?)?.toInt();
    return BookReadingResume(
      chapterIndex: first,
      throughChapterIndex: through != null && through > first ? through : null,
      scrollOffset: (json['scrollOffset'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// Last reading position per book (chapter index + scroll offset).
class BookReadingProgress {
  BookReadingProgress(this.prefs);

  final SharedPreferences prefs;

  static String _posKey(String bookId) => 'wx.bookPos.$bookId';
  static String _openedKey(String bookId) => 'wx.bookOpened.$bookId';

  DateTime? openedAt(String bookId) {
    final raw = prefs.getString(_openedKey(bookId));
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  Future<void> markOpened(String bookId) {
    return prefs.setString(
      _openedKey(bookId),
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  BookReadingResume? resume(String bookId) {
    final raw = prefs.getString(_posKey(bookId));
    if (raw == null || raw.isEmpty) return null;
    try {
      return BookReadingResume.fromJson(
        Map<String, dynamic>.from(jsonDecode(raw) as Map),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> saveResume(String bookId, BookReadingResume position) async {
    await prefs.setString(_posKey(bookId), jsonEncode(position.toJson()));
  }

  Future<void> clear(String bookId) async {
    await prefs.remove(_posKey(bookId));
    await prefs.remove(_openedKey(bookId));
  }
}

/// Newest open time first. Books never opened keep their previous order at the end.
List<T> sortByLastOpened<T>(
  List<T> items,
  DateTime? Function(T item) openedAt,
) {
  final indexed = [
    for (var i = 0; i < items.length; i++) (index: i, item: items[i]),
  ];
  indexed.sort((a, b) {
    final ao = openedAt(a.item);
    final bo = openedAt(b.item);
    if (ao == null && bo == null) return a.index.compareTo(b.index);
    if (ao == null) return 1;
    if (bo == null) return -1;
    final cmp = bo.compareTo(ao);
    if (cmp != 0) return cmp;
    return a.index.compareTo(b.index);
  });
  return [for (final row in indexed) row.item];
}
