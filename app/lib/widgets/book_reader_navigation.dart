import 'package:flutter/widgets.dart';

double readerBookProgress({
  required int chapterIndex,
  required int chapterCount,
  double chapterScrollFraction = 0,
}) {
  if (chapterCount <= 0) return 0;
  final frac = chapterScrollFraction.clamp(0.0, 1.0);
  if (chapterCount == 1) return frac;
  final slice = 1 / (chapterCount - 1);
  return ((chapterIndex * slice) + (slice * frac)).clamp(0.0, 1.0);
}

String readerProgressLabel({
  required int chapterIndex,
  required int chapterCount,
  double chapterScrollFraction = 0,
}) {
  if (chapterCount <= 0) return '0%';
  final pct =
      (readerBookProgress(
            chapterIndex: chapterIndex,
            chapterCount: chapterCount,
            chapterScrollFraction: chapterScrollFraction,
          ) *
          100)
      .round()
      .clamp(0, 100);
  return '$pct% · ${chapterIndex + 1}/$chapterCount 章';
}

bool readerCanGoPrev(int chapterIndex) => chapterIndex > 0;

bool readerCanGoNext(int chapterIndex, int chapterCount) =>
    chapterCount > 0 && chapterIndex < chapterCount - 1;

double readerScrollFraction(ScrollController controller) {
  if (!controller.hasClients) return 0;
  final pos = controller.position;
  if (pos.maxScrollExtent <= 0) return 0;
  return (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
}
