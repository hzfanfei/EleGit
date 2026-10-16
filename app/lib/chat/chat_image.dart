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
  static const _max = 24;
  static final List<String> _order = [];
  static final Map<String, List<int>> _bytes = {};

  static void put(String id, List<int> bytes) {
    if (id.isEmpty) return;
    _bytes[id] = bytes;
    _order.remove(id);
    _order.add(id);
    while (_order.length > _max) {
      _bytes.remove(_order.removeAt(0));
    }
  }

  static List<int>? get(String id) => _bytes[id];
}
