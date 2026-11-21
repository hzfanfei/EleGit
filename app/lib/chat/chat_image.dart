import 'dart:typed_data';

import '../utils/image_bytes_cache.dart';

const chatImageMaxBytes = 4 * 1024 * 1024;
const chatImageMaxCount = 4;

const chatImageMimes = {
  'image/jpeg',
  'image/png',
  'image/webp',
  'image/gif',
};

String chatImageMime({String? mimeType, String? path}) {
  final mime = (mimeType ?? '').toLowerCase().split(';').first.trim();
  if (mime == 'image/jpg' || mime == 'image/pjpeg') return 'image/jpeg';
  if (chatImageMimes.contains(mime)) return mime;
  final name = (path ?? '').toLowerCase();
  if (name.endsWith('.png')) return 'image/png';
  if (name.endsWith('.webp')) return 'image/webp';
  if (name.endsWith('.gif')) return 'image/gif';
  return 'image/jpeg';
}

/// Bytes already uploaded this session, so the bubble can paint without another fetch.
class ChatImageCache {
  static final _cache =
      ImageBytesCache(maxEntries: 24, maxBytes: 24 * 1024 * 1024);

  static void put(String id, Uint8List bytes) {
    if (id.isNotEmpty) _cache.put(id, bytes);
  }

  static Uint8List? get(String id) => _cache.get(id);
  static void remove(String id) => _cache.remove(id);
}
