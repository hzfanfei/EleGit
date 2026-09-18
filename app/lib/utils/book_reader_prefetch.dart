/// How many upcoming chapters to keep in memory ahead of the visible tail.
const kReaderPrefetchAhead = 2;

/// Append the next chapter this many pixels before the current bottom.
const kReaderAppendLeadPx = 1600;

bool readerShouldAppendNext({
  required double pixels,
  required double maxExtent,
  required int rangeLast,
  required int chapterCount,
}) {
  if (rangeLast + 1 >= chapterCount) return false;
  if (maxExtent <= 0) return true;
  return pixels >= maxExtent - kReaderAppendLeadPx;
}

List<int> readerPrefetchTargets({
  required int rangeLast,
  required int chapterCount,
  int ahead = kReaderPrefetchAhead,
}) {
  final out = <int>[];
  for (var i = 1; i <= ahead; i++) {
    final index = rangeLast + i;
    if (index < chapterCount) out.add(index);
  }
  return out;
}
