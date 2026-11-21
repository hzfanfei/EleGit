import 'dart:typed_data';

/// A bounded cache for encoded images. Decoded images use Flutter's ImageCache.
class ImageBytesCache {
  ImageBytesCache({required this.maxEntries, required this.maxBytes});

  final int maxEntries;
  final int maxBytes;
  final _entries = <String, Uint8List>{};
  int _size = 0;

  Uint8List? get(String key) {
    final bytes = _entries.remove(key);
    if (bytes != null) _entries[key] = bytes;
    return bytes;
  }

  void put(String key, Uint8List bytes) {
    remove(key);
    if (bytes.lengthInBytes > maxBytes) return;
    _entries[key] = bytes;
    _size += bytes.lengthInBytes;
    while (_size > maxBytes || _entries.length > maxEntries) {
      remove(_entries.keys.first);
    }
  }

  void remove(String key) {
    _size -= _entries.remove(key)?.lengthInBytes ?? 0;
  }
}
