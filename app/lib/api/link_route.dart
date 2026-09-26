/// Whether [raw] is a same-network address (loopback or private IPv4).
bool isLanBaseUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return false;
  final host = uri.host.toLowerCase();
  if (host == 'localhost' || host == '::1') return true;
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final nums = parts.map(int.tryParse).toList();
  if (nums.any((n) => n == null || n! < 0 || n > 255)) return false;
  final a = nums[0]!;
  final b = nums[1]!;
  if (a == 10 || a == 127) return true;
  if (a == 192 && b == 168) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  return false;
}

/// 局域网 when the phone is talking to a private address, otherwise 穿透.
String linkRouteLabel(String raw) => isLanBaseUrl(raw) ? '局域网' : '穿透';

String normalizeBaseUrl(String raw) => raw.trim().replaceAll(RegExp(r'/$'), '');

/// First private URL in [urls] for which [reachable] returns true.
String? pickLanBase(List<String> urls, {required bool Function(String url) reachable}) {
  for (final raw in urls) {
    final url = normalizeBaseUrl(raw);
    if (url.isEmpty || !isLanBaseUrl(url)) continue;
    if (reachable(url)) return url;
  }
  return null;
}
