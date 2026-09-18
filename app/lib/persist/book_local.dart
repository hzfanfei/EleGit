import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BookLocalStore {
  BookLocalStore(this.prefs);

  final SharedPreferences prefs;

  static const _pathsKey = 'wx.bookLocalPaths';

  Map<String, String> _readMap() {
    final raw = prefs.getString(_pathsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
    } catch (_) {
      return {};
    }
  }

  String? localPath(String bookId) {
    final path = _readMap()[bookId];
    if (path == null || path.isEmpty) return null;
    if (!File(path).existsSync()) return null;
    return path;
  }

  Future<void> remember(String bookId, String path) async {
    final next = _readMap()..[bookId] = path;
    await prefs.setString(_pathsKey, jsonEncode(next));
  }

  Future<void> forget(String bookId) async {
    final next = _readMap()..remove(bookId);
    await prefs.setString(_pathsKey, jsonEncode(next));
  }

  static Future<String> targetPath(String bookId, String filename) async {
    final dir = await getApplicationDocumentsDirectory();
    final root = Directory('${dir.path}/wenxiang-books');
    if (!root.existsSync()) {
      await root.create(recursive: true);
    }
    final safeName = filename.trim().isEmpty ? '$bookId.epub' : filename;
    return '${root.path}/$safeName';
  }
}
