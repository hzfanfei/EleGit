import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Local error reasons, uploaded later from the shell.
class ClientErrorLog {
  ClientErrorLog({Directory? root, this.maxEntries = 200, this.persist = true}) : _root = root;

  static ClientErrorLog instance = ClientErrorLog();

  static const debounce = Duration(minutes: 2);

  final Directory? _root;
  final int maxEntries;
  final bool persist;
  final List<Map<String, dynamic>> _entries = [];
  final Map<String, DateTime> _seen = {};
  Future<void> _tail = Future<void>.value();
  bool _loaded = false;
  int _seq = 0;

  Future<void> get idle => _tail;

  void note({
    required String message,
    String summary = '',
    String stack = '',
    String kind = 'error',
  }) {
    try {
      final cleaned = redactSecrets(message).trim();
      if (cleaned.isEmpty || cleaned == 'cancelled') return;
      final now = DateTime.now();
      final previous = _seen[cleaned];
      if (previous != null && now.difference(previous) < debounce) return;
      _seen[cleaned] = now;
      if (_seen.length > 200) _seen.remove(_seen.keys.first);
      _seq += 1;
      final entry = <String, dynamic>{
        'id': '${now.microsecondsSinceEpoch}-$_seq',
        'at': now.toUtc().toIso8601String(),
        'kind': _clip(kind, 40),
        'message': _clip(cleaned, 2000),
        'summary': _clip(redactSecrets(summary).trim(), 500),
        'stack': _clip(redactSecrets(stack), 4000),
      };
      unawaited(
        _enqueue(() => _add(entry)).then((_) {}, onError: (Object error, StackTrace stack) {}),
      );
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> peek(int limit) {
    return _enqueue(() async {
      await _load();
      final take = limit < 0 ? 0 : limit;
      return [
        for (final entry in _entries.take(take)) Map<String, dynamic>.from(entry),
      ];
    });
  }

  Future<void> drop(Iterable<String> ids) {
    return _enqueue(() async {
      await _load();
      final remove = ids.toSet();
      _entries.removeWhere((entry) => remove.contains(entry['id']));
      await _save();
    });
  }

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final done = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        final value = await action();
        if (!done.isCompleted) done.complete(value);
      } catch (err, stack) {
        if (!done.isCompleted) done.completeError(err, stack);
      }
    });
    return done.future;
  }

  Future<void> _add(Map<String, dynamic> entry) async {
    await _load();
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    await _save();
  }

  Future<void> _load() async {
    if (_loaded) return;
    final file = await _file();
    if (file == null) return;
    _loaded = true;
    final pending = [for (final entry in _entries) Map<String, dynamic>.from(entry)];
    _entries.clear();
    if (await file.exists()) {
      final lines = await file.readAsLines();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            _entries.add(Map<String, dynamic>.from(decoded));
          }
        } catch (_) {}
      }
    }
    _entries.addAll(pending);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
  }

  Future<void> _save() async {
    final file = await _file();
    if (file == null) return;
    final text = _entries.map(jsonEncode).join('\n');
    await file.writeAsString(text.isEmpty ? '' : '$text\n', flush: true);
  }

  Future<File?> _file() async {
    final dir = await _directory();
    if (dir == null) return null;
    return File('${dir.path}${Platform.pathSeparator}client-errors.jsonl');
  }

  Future<Directory?> _directory() async {
    if (!persist) return null;
    if (_root != null) {
      await _root.create(recursive: true);
      return _root;
    }
    if (Platform.environment['FLUTTER_TEST'] == 'true') return null;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}${Platform.pathSeparator}wenxiang-errors');
      await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }
}

String redactSecrets(String text) {
  return text
      .replaceAll(
        RegExp(r'X-Wenxiang-Key\s*[:=]\s*\S+', caseSensitive: false),
        'X-Wenxiang-Key: [redacted]',
      )
      .replaceAllMapped(
        RegExp(r'("apiKey"\s*:\s*")[^"]+', caseSensitive: false),
        (match) => '${match[1]}[redacted]',
      )
      .replaceAll(RegExp(r'\b(?:ghp_|github_pat_|sk-)[A-Za-z0-9_\-]+'), '[redacted]')
      .replaceAll(RegExp(r'\bBearer\s+\S+', caseSensitive: false), 'Bearer [redacted]');
}

String _clip(String value, int max) {
  if (value.length <= max) return value;
  return value.substring(0, max);
}
