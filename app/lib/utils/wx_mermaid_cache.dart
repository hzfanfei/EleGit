import '../api/wenxiang_api.dart';

/// In-memory diagrams. List items are disposed when they scroll away, so the
/// widget state cannot be the only copy of a rendered image.
class WxMermaidCache {
  WxMermaidCache._();

  static final instance = WxMermaidCache._();

  static const maxEntries = 32;

  final _entries = <String, MermaidRender>{};
  final _order = <String>[];
  final _inflight = <String, Future<MermaidRender>>{};

  static String key({
    required String code,
    required String theme,
    required String backgroundColor,
  }) {
    return '${theme.trim()}\u0000${backgroundColor.trim()}\u0000${code.trim()}';
  }

  MermaidRender? peek(String key) {
    final hit = _entries[key];
    if (hit == null) return null;
    _touch(key);
    return hit;
  }

  void remember(String key, MermaidRender value) {
    if (value.png == null && (value.svg == null || value.svg!.isEmpty)) return;
    _entries[key] = value;
    _touch(key);
    while (_order.length > maxEntries) {
      final oldest = _order.removeAt(0);
      _entries.remove(oldest);
    }
  }

  /// One network render per diagram. Later callers share the in-flight future.
  Future<MermaidRender> load(String key, Future<MermaidRender> Function() fetch) {
    final hit = peek(key);
    if (hit != null) return Future<MermaidRender>.value(hit);
    final pending = _inflight[key];
    if (pending != null) return pending;
    final future = fetch().then((value) {
      remember(key, value);
      return value;
    });
    _inflight[key] = future;
    future.whenComplete(() {
      if (identical(_inflight[key], future)) _inflight.remove(key);
    });
    return future;
  }

  void _touch(String key) {
    _order.remove(key);
    _order.add(key);
  }

  void clear() {
    _entries.clear();
    _order.clear();
    _inflight.clear();
  }
}
