import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/book_markdown_body.dart';
import '../api/wenxiang_api.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../persist/book_chat_store.dart';
import '../persist/book_reader_prefs.dart';
import '../persist/book_reading_progress.dart';
import '../theme.dart';
import '../utils/book_markdown_markup.dart';
import '../utils/book_reader_markdown_style.dart';
import '../utils/book_reader_prefetch.dart';
import '../voice/book_quick_voice_session.dart';
import '../widgets/book_ask_panel.dart';
import '../widgets/book_quick_voice_fab.dart';
import '../widgets/book_reader_chrome.dart';
import '../widgets/book_reader_navigation.dart';
import '../widgets/book_reader_settings_sheet.dart';
import '../widgets/book_reader_toc_sheet.dart';
import '../widgets/wx_chrome.dart';

class BookReaderPage extends StatefulWidget {
  const BookReaderPage({
    super.key,
    required this.api,
    required this.book,
    required this.onBack,
    this.expandAsk = false,
    this.prefs,
    this.memory,
  });

  final WenxiangApi api;
  final BookItem book;
  final VoidCallback onBack;
  final bool expandAsk;
  final SharedPreferences? prefs;
  final AppMemory? memory;

  @override
  State<BookReaderPage> createState() => _BookReaderPageState();
}

class _BookReaderPageState extends State<BookReaderPage> with WidgetsBindingObserver {
  Object? _loadError;
  bool _chapterLoading = false;
  bool _loadingTail = false;
  bool _maintainingPrefetch = false;
  final Map<int, Future<String?>> _chapterFetches = {};
  BookReadingManifest? _manifest;
  int _rangeFirst = 0;
  int _rangeLast = 0;
  int _activeChapterIndex = 0;
  final Map<int, String> _chapterMarkdownByIndex = {};
  bool _chromeVisible = true;
  Timer? _chromeHide;
  Timer? _saveDebounce;
  final _sheetSize = ValueNotifier<double>(0);
  final _readingPlace = ValueNotifier(const BookReadingPlace());
  final _scrollController = ScrollController();
  final _askScrollController = ScrollController();
  final _askBoxKey = GlobalKey();
  final _askPanelKey = GlobalKey<BookAskPanelState>();
  BookAskSheetLevel _askLevel = BookAskSheetLevel.hidden;
  BookAskSheetLevel _askShellLevel = BookAskSheetLevel.hidden;
  double _askHeight = 0;
  BookReadingProgress? _progress;
  BookReaderPrefs? _readerPrefs;
  ReaderSettings _settings = const ReaderSettings();
  String _chapterHint = '';
  String _progressLabel = '';
  String _openingHint = '正在读取目录…';
  double _bookProgress = 0;
  double _scrollFraction = 0;
  late final BookQuickVoiceSession _quickVoice;
  bool _voiceReady = false;

  static const _askExpandedSheet = kBookAskHalfFraction;
  static const _askFullSheet = kBookAskFullFraction;

  @override
  void initState() {
    super.initState();
    _askLevel = widget.expandAsk ? BookAskSheetLevel.half : BookAskSheetLevel.hidden;
    _askShellLevel = _askLevel;
    _sheetSize.value = _fractionForAskLevel(_askLevel);
    _scrollController.addListener(_onScroll);
    _hydratePrefs(widget.prefs);
    _chapterHint = widget.book.author.isEmpty ? '阅读' : widget.book.author;
    _quickVoice = BookQuickVoiceSession(
      api: widget.api,
      bookId: widget.book.id,
      chapterHint: _chapterHint,
      readingPlace: () => _readingPlace.value,
      historyForVoice: (place) =>
          _askPanelKey.currentState?.chatHistoryForVoice(place) ?? const [],
      onTurnRecorded: ({
        required place,
        required question,
        required answer,
        engine,
        sessionId,
      }) async {
        await _askPanelKey.currentState?.recordVoiceTurn(
          place: place,
          question: question,
          answer: answer,
          engine: engine,
          sessionId: sessionId,
        );
      },
      onChanged: () {
        if (mounted) setState(() {});
      },
      onError: (message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
    );
    unawaited(_warmInBackground());
    unawaited(_loadVoiceStatus());
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_openBook());
      _scheduleChromeHide();
      _applySystemChrome();
    });
  }

  Future<void> _warmInBackground() async {
    try {
      await widget.api.warmBookSession(widget.book.id);
    } catch (_) {}
  }

  Future<void> _loadVoiceStatus() async {
    try {
      final status = await widget.api.status();
      if (!mounted) return;
      setState(() => _voiceReady = status.voiceReady);
    } catch (_) {
      if (!mounted) return;
      setState(() => _voiceReady = false);
    }
  }

  void _hydratePrefs(SharedPreferences? prefs) {
    if (prefs == null) return;
    _progress = BookReadingProgress(prefs);
    _readerPrefs = BookReaderPrefs(prefs);
    _settings = _readerPrefs!.load();
    _applySystemChrome();
  }

  Future<void> _openBook() async {
    SharedPreferences? prefs = widget.prefs;
    if (prefs == null) {
      prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      _hydratePrefs(prefs);
      setState(() {});
    }
    try {
      if (mounted) setState(() => _openingHint = '正在读取目录…');
      final manifest = await widget.api.fetchBookReadingManifest(widget.book.id);
      if (!mounted) return;
      if (manifest.chapters.isEmpty) {
        setState(() => _loadError = '本书没有可读章节，请确认 companion 已物化 EPUB。');
        return;
      }
      final resume = _progress!.resume(widget.book.id);
      final first = (resume?.chapterIndex ?? 0).clamp(0, manifest.chapters.length - 1);
      setState(() {
        _manifest = manifest;
        _chapterLoading = true;
        _openingHint = '正在载入章节…';
        _rangeFirst = first;
        _rangeLast = first;
        _activeChapterIndex = first;
      });
      _updateChapterHint(first);
      await _loadChapterRange(first, first);
      if (!mounted) return;
      setState(() {
        _activeChapterIndex = first;
        _openingHint = '';
        _updateChapterHint(first);
      });
      // Only restore pixel offset when resume was single-chapter; multi-chapter
      // scroll offsets would jump past the only loaded chapter and look blank.
      final restoreScroll = resume != null &&
          (resume.throughChapterIndex == null || resume.lastChapter == resume.chapterIndex);
      final offset = restoreScroll ? (resume!.scrollOffset) : 0.0;
      _restoreScrollOffset(offset);
      unawaited(_maintainPrefetch());
    } catch (err) {
      if (!mounted) return;
      setState(() => _loadError = err);
    }
  }

  void _restoreScrollOffset(double offset) {
    void apply() {
      if (!_scrollController.hasClients) return;
      final max = _scrollController.position.maxScrollExtent;
      _scrollController.jumpTo(offset.clamp(0.0, max));
      _syncActiveChapterFromScroll();
      _refreshProgressLabels();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      apply();
      unawaited(_maintainPrefetch());
      // Markdown layout may grow after first frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        apply();
        unawaited(_maintainPrefetch());
      });
    });
  }

  void _updateChapterHint(int index) {
    final manifest = _manifest;
    if (manifest == null || index < 0 || index >= manifest.chapters.length) return;
    final title = manifest.chapters[index].title.trim();
    _chapterHint = title.isEmpty ? '第 ${index + 1} 章' : title;
    _quickVoice.chapterHint = _chapterHint;
  }

  Future<String?> _fetchChapterMarkdown(int index) async {
    final manifest = _manifest;
    if (manifest == null || index < 0 || index >= manifest.chapters.length) return null;
    final cached = _chapterMarkdownByIndex[index];
    if (cached != null) return cached;
    return _chapterFetches.putIfAbsent(index, () async {
      try {
        final file = manifest.chapters[index].file;
        final md = await widget.api.fetchBookChapterMarkdown(widget.book.id, file);
        _chapterMarkdownByIndex[index] = md;
        return md;
      } finally {
        _chapterFetches.remove(index);
      }
    });
  }

  Future<void> _loadChapterRange(int first, int last) async {
    final manifest = _manifest;
    if (manifest == null) return;
    setState(() {
      _chapterLoading = true;
      _rangeFirst = first;
      _rangeLast = first;
    });
    try {
      for (var i = first; i <= last; i++) {
        await _fetchChapterMarkdown(i);
        if (!mounted) return;
        setState(() => _rangeLast = i);
      }
      if (!mounted) return;
      setState(() => _chapterLoading = false);
      _publishReadingPlace();
      _refreshProgressLabels();
    } catch (err) {
      if (!mounted) return;
      setState(() => _chapterLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('加载章节失败：$err'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _onBookLink(String href, String text) async {
    final external = bookMarkdownExternalUri(href);
    if (external != null) {
      final opened = await launchUrl(external, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开链接：$href'), behavior: SnackBarBehavior.floating),
        );
      }
      return;
    }
    final manifest = _manifest;
    if (manifest == null) return;
    final index = resolveBookMarkdownChapterLink(
      href: href,
      text: text,
      chapters: manifest.chapters,
      toc: manifest.toc,
    );
    if (index == null || index == _activeChapterIndex) return;
    await _jumpToChapter(index);
  }

  Future<void> _jumpToChapter(int index, {double scrollOffset = 0}) async {
    final manifest = _manifest;
    if (manifest == null || index < 0 || index >= manifest.chapters.length) return;
    await _loadChapterRange(index, index);
    if (!mounted) return;
    setState(() => _activeChapterIndex = index);
    _updateChapterHint(index);
    _publishReadingPlace();
    _restoreScrollOffset(scrollOffset);
    unawaited(_maintainPrefetch());
  }

  Future<void> _maintainPrefetch() async {
    final manifest = _manifest;
    if (_maintainingPrefetch || _chapterLoading || manifest == null) return;
    _maintainingPrefetch = true;
    try {
      for (final index in readerPrefetchTargets(
        rangeLast: _rangeLast,
        chapterCount: manifest.chapters.length,
      )) {
        unawaited(_fetchChapterMarkdown(index));
      }
      if (!_scrollController.hasClients) return;
      final pos = _scrollController.position;
      if (!readerShouldAppendNext(
        pixels: pos.pixels,
        maxExtent: pos.maxScrollExtent,
        rangeLast: _rangeLast,
        chapterCount: manifest.chapters.length,
      )) {
        return;
      }
      final next = _rangeLast + 1;
      if (_chapterMarkdownByIndex[next] == null) {
        if (mounted) setState(() => _loadingTail = true);
        try {
          await _fetchChapterMarkdown(next);
        } catch (err) {
          if (!mounted) return;
          setState(() => _loadingTail = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('加载下一章失败：$err'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }
        if (!mounted) return;
        setState(() => _loadingTail = false);
      }
      if (!mounted || _chapterMarkdownByIndex[next] == null) return;
      setState(() => _rangeLast = next);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_maintainPrefetch());
      });
    } finally {
      _maintainingPrefetch = false;
    }
  }

  void _syncActiveChapterFromScroll() {
    final manifest = _manifest;
    if (manifest == null || !_scrollController.hasClients) return;
    final span = _rangeLast - _rangeFirst + 1;
    if (span <= 1) {
      if (_activeChapterIndex != _rangeFirst) {
        setState(() {
          _activeChapterIndex = _rangeFirst;
          _updateChapterHint(_activeChapterIndex);
        });
        _publishReadingPlace();
      }
      return;
    }
    final pos = _scrollController.position;
    final frac = pos.maxScrollExtent <= 0
        ? 0.0
        : (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
    final idx = (_rangeFirst + frac * (span - 1)).round().clamp(_rangeFirst, _rangeLast);
    if (idx != _activeChapterIndex) {
      setState(() {
        _activeChapterIndex = idx;
        _updateChapterHint(idx);
      });
      _publishReadingPlace();
    }
  }

  ({int chapterIndex, double chapterScrollFraction}) _continuousProgress() {
    final manifest = _manifest;
    if (manifest == null || !_scrollController.hasClients) {
      return (chapterIndex: _activeChapterIndex, chapterScrollFraction: 0.0);
    }
    final total = manifest.chapters.length;
    if (total <= 0) {
      return (chapterIndex: 0, chapterScrollFraction: 0.0);
    }
    final span = _rangeLast - _rangeFirst + 1;
    if (span <= 1) {
      return (
        chapterIndex: _rangeFirst,
        chapterScrollFraction: readerScrollFraction(_scrollController),
      );
    }
    final pos = _scrollController.position;
    final frac = pos.maxScrollExtent <= 0
        ? 0.0
        : (pos.pixels / pos.maxScrollExtent).clamp(0.0, 1.0);
    final floatIndex = _rangeFirst + frac * (span - 1);
    final chapter = floatIndex.floor().clamp(0, total - 1);
    final chapterFrac = (floatIndex - chapter).clamp(0.0, 1.0);
    return (chapterIndex: chapter, chapterScrollFraction: chapterFrac);
  }

  SystemUiOverlayStyle _systemOverlayStyle() => bookReaderSystemOverlayStyle(_settings);

  void _applySystemChrome() {
    // Overlay style only. Re-entering edgeToEdge on chrome hide / IME
    // collapse is the OEM sliding white status-bar animation.
    SystemChrome.setSystemUIOverlayStyle(_systemOverlayStyle());
  }

  void _refreshProgressLabels() {
    final count = _manifest?.chapters.length ?? 0;
    final continuous = _continuousProgress();
    final label = readerProgressLabel(
      chapterIndex: continuous.chapterIndex,
      chapterCount: count,
      chapterScrollFraction: continuous.chapterScrollFraction,
    );
    final progress = readerBookProgress(
      chapterIndex: continuous.chapterIndex,
      chapterCount: count,
      chapterScrollFraction: continuous.chapterScrollFraction,
    );
    final frac = continuous.chapterScrollFraction;
    if (label != _progressLabel ||
        (progress - _bookProgress).abs() > 0.002 ||
        (frac - _scrollFraction).abs() > 0.02) {
      setState(() {
        _progressLabel = label;
        _bookProgress = progress;
        _scrollFraction = frac;
      });
    }
  }

  void _onScroll() {
    _syncActiveChapterFromScroll();
    _refreshProgressLabels();
    unawaited(_maintainPrefetch());
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 400), _saveProgress);
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
    _applySystemChrome();
    _scheduleChromeHide();
  }

  void _scheduleChromeHide() {
    _chromeHide?.cancel();
    if (!_chromeVisible) return;
    _chromeHide = Timer(const Duration(seconds: 5), () {
      if (!mounted) return;
      setState(() => _chromeVisible = false);
      _applySystemChrome();
    });
  }

  void _measureAskPanel() {
    final box = _askBoxKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final next = box.size.height;
    if ((next - _askHeight).abs() < 0.5) return;
    setState(() => _askHeight = next);
  }

  double _fractionForAskLevel(BookAskSheetLevel level) {
    switch (level) {
      case BookAskSheetLevel.hidden:
        return 0;
      case BookAskSheetLevel.dock:
        return 0;
      case BookAskSheetLevel.half:
        return _askExpandedSheet;
      case BookAskSheetLevel.full:
        return _askFullSheet;
    }
  }

  bool _askLevelIsPeek(BookAskSheetLevel level) =>
      level == BookAskSheetLevel.hidden || level == BookAskSheetLevel.dock;

  Future<void> _setAskLevel(BookAskSheetLevel level) async {
    if (_askLevel == level) return;
    HapticFeedback.selectionClick();
    if (!mounted) return;
    if (_askLevelIsPeek(level)) {
      FocusManager.instance.primaryFocus?.unfocus();
    }
    final deferShellShrink =
        _askLevelIsPeek(level) && !_askLevelIsPeek(_askLevel);
    setState(() {
      _askLevel = level;
      _askHeight = 0;
      _sheetSize.value = _fractionForAskLevel(level);
      if (!deferShellShrink) {
        _askShellLevel = level;
      }
    });
    if (deferShellShrink) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _askLevel != level) return;
        setState(() => _askShellLevel = level);
      });
    }
  }

  Future<void> _collapseAskSheet() => _setAskLevel(stepAskSheetDown(_askLevel));

  Future<void> _ensureAskHalf() async {
    if (_askLevel == BookAskSheetLevel.hidden || _askLevel == BookAskSheetLevel.dock) {
      await _setAskLevel(BookAskSheetLevel.half);
    }
  }

  void _publishReadingPlace() {
    _readingPlace.value = BookReadingPlace(chapter: _chapterHint);
  }

  Future<void> _saveProgress() async {
    final store = _progress;
    if (store == null) return;
    final offset = _scrollController.hasClients ? _scrollController.offset : 0.0;
    await store.saveResume(
      widget.book.id,
      BookReadingResume(
        chapterIndex: _rangeFirst,
        throughChapterIndex: _rangeLast > _rangeFirst ? _rangeLast : null,
        scrollOffset: offset,
      ),
    );
    if (!mounted) return;
    _publishReadingPlace();
  }

  Future<void> _saveSettings(ReaderSettings settings) async {
    setState(() => _settings = settings);
    _applySystemChrome();
    await _readerPrefs?.save(settings);
  }

  void _showSettings() {
    _chromeHide?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _chromeVisible = true);
    _applySystemChrome();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => BookReaderSettingsSheet(
        initial: _settings,
        onChanged: (next) => unawaited(_saveSettings(next)),
      ),
    ).whenComplete(_scheduleChromeHide);
  }

  void _showToc() {
    final manifest = _manifest;
    if (manifest == null) return;
    _chromeHide?.cancel();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _chromeVisible = true);
    _applySystemChrome();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => BookReaderTocSheet(
        toc: manifest.toc,
        currentIndex: _activeChapterIndex,
        onPick: (index) {
          Navigator.of(context).pop();
          unawaited(_jumpToChapter(index));
          _scheduleChromeHide();
        },
      ),
    ).whenComplete(_scheduleChromeHide);
  }

  void _leave() {
    unawaited(_saveProgress());
    widget.onBack();
  }

  @override
  void didChangeMetrics() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveProgress());
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    _quickVoice.dispose();
    _chromeHide?.cancel();
    _saveDebounce?.cancel();
    _scrollController.dispose();
    _askScrollController.dispose();
    _sheetSize.dispose();
    _readingPlace.dispose();
    super.dispose();
  }

  double _scrimOpacity(double size) {
    if (size <= 0.08) return 0;
    final t = (size / _askFullSheet).clamp(0.0, 1.0);
    return (t * 0.42).clamp(0.0, 0.42);
  }

  @override
  Widget build(BuildContext context) {
    final palette = _settings.palette;

    if (_loadError != null) {
      return Scaffold(
        body: Column(
          children: [
            WxPageHeader(
              showMark: false,
              title: widget.book.title,
              subtitle: '阅读',
              onBack: widget.onBack,
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: Wx.pagePadding,
                  child: Text(_loadError.toString(), textAlign: TextAlign.center),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final manifest = _manifest;
    final media = MediaQuery.of(context);
    final topContentPad = bookReaderTopContentPad(
      chromeVisible: _chromeVisible,
      media: media,
    );
    final styleSheet = bookReaderMarkdownStyle(
      theme: Theme.of(context),
      palette: palette,
      settings: _settings,
    );

    WidgetsBinding.instance.addPostFrameCallback((_) => _measureAskPanel());

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemOverlayStyle(),
      child: Scaffold(
        backgroundColor: palette.paper,
        resizeToAvoidBottomInset: false,
        body: ValueListenableBuilder<double>(
          valueListenable: _sheetSize,
          builder: (context, sheetFraction, _) {
            final h = media.size.height;
            final keyboard = MediaQuery.viewInsetsOf(context).bottom;
            final askExpanded = _askShellLevel == BookAskSheetLevel.half ||
                _askShellLevel == BookAskSheetLevel.full;
            final layoutHeight = (h - keyboard).clamp(0.0, h);
            final fraction = sheetFraction.clamp(0.0, _askFullSheet);
            final panelH = bookReaderAskReserve(
              level: _askShellLevel,
              viewportHeight: layoutHeight,
              estimatedDockHeight: BookAskPanel.estimatedDockHeight(media),
              estimatedHiddenHeight: BookAskPanel.estimatedHiddenHeight(media),
              measuredHeight: _askHeight,
            );
            final readerBottom = panelH + keyboard;
            final panelHeight = switch (_askShellLevel) {
              BookAskSheetLevel.hidden ||
              BookAskSheetLevel.dock =>
                BookAskPanel.estimatedHiddenHeight(media),
              BookAskSheetLevel.half || BookAskSheetLevel.full =>
                layoutHeight * _fractionForAskLevel(_askShellLevel),
            };

            return Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  bottom: readerBottom,
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: _toggleChrome,
                    child: ColoredBox(
                      key: const Key('book-reader-body'),
                      color: palette.paper,
                      child: _chapterMarkdownByIndex.isEmpty
                        ? _OpeningSkeleton(
                            palette: palette,
                            title: widget.book.title,
                            hint: _openingHint.isEmpty ? '正在载入章节…' : _openingHint,
                            padding: EdgeInsets.fromLTRB(
                              _settings.horizontalPadding,
                              topContentPad,
                              _settings.horizontalPadding,
                              24,
                            ),
                          )
                        : ListView.builder(
                            controller: _scrollController,
                            cacheExtent: 2400,
                            padding: EdgeInsets.fromLTRB(
                              _settings.horizontalPadding,
                              topContentPad,
                              _settings.horizontalPadding,
                              24,
                            ),
                            itemCount: (_rangeLast - _rangeFirst + 1) + (_loadingTail ? 1 : 0),
                            itemBuilder: (context, itemIndex) {
                              final span = _rangeLast - _rangeFirst + 1;
                              if (itemIndex >= span) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                );
                              }
                              final chapterIndex = _rangeFirst + itemIndex;
                              final md = _chapterMarkdownByIndex[chapterIndex];
                              if (md == null) {
                                return const Padding(
                                  padding: EdgeInsets.symmetric(vertical: 24),
                                  child: Center(
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  ),
                                );
                              }
                              final chapter = manifest?.chapters[chapterIndex];
                              final title = chapter?.title.trim() ?? '';
                              final heading = title.isEmpty ? '第 ${chapterIndex + 1} 章' : title;
                              final body = md.trim().isEmpty ? '本章暂无正文。' : md;
                              return RepaintBoundary(
                                child: Padding(
                                  padding: EdgeInsets.only(top: itemIndex == 0 ? 0 : 28),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.stretch,
                                    children: [
                                      Text(heading, style: styleSheet.h2),
                                      const SizedBox(height: 12),
                                      BookMarkdownBody(
                                        api: widget.api,
                                        bookId: widget.book.id,
                                        chapterFile: chapter?.file ?? '',
                                        spineHref: chapter?.href,
                                        data: body,
                                        styleSheet: styleSheet,
                                        onTapLink: _onBookLink,
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: _scrimOpacity(fraction) <= 0,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => unawaited(_collapseAskSheet()),
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 220),
                        opacity: _scrimOpacity(fraction),
                        child: const ColoredBox(color: Colors.black),
                      ),
                    ),
                  ),
                ),
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(
                    ignoring: !_chromeVisible,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 200),
                      opacity: _chromeVisible ? 1 : 0,
                      child: BookReaderChrome(
                        title: widget.book.title,
                        chapter: _chapterHint.isEmpty
                            ? '第 ${_activeChapterIndex + 1} 章'
                            : _chapterHint,
                        progressLabel: _progressLabel,
                        palette: palette,
                        onBack: _leave,
                        onOpenToc: _showToc,
                        onOpenSettings: _showSettings,
                      ),
                    ),
                  ),
                ),
                if (h - readerBottom >= 160)
                  Positioned(
                    left: 8,
                    right: 0,
                    bottom: readerBottom,
                    child: Align(
                      alignment: Alignment.bottomRight,
                      child: BookQuickVoiceFab(
                        session: _quickVoice,
                        palette: palette,
                        enabled: _voiceReady,
                      ),
                    ),
                  ),
                if (keyboard > 0)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    height: keyboard,
                    child: ColoredBox(color: askExpanded ? Wx.bg : palette.paper),
                  ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: keyboard,
                  height: panelHeight,
                  child: KeyedSubtree(
                    key: _askBoxKey,
                    child: BookAskPanel(
                      key: _askPanelKey,
                      api: widget.api,
                      book: widget.book,
                      scrollController: _askScrollController,
                      sheetSize: _sheetSize,
                      hidden: _askLevel == BookAskSheetLevel.hidden ||
                          _askLevel == BookAskSheetLevel.dock,
                      expanded: _askLevel == BookAskSheetLevel.half ||
                          _askLevel == BookAskSheetLevel.full,
                      fullscreen: _askLevel == BookAskSheetLevel.full,
                      chapterHint: _chapterHint,
                      readingPlace: _readingPlace,
                      memory: widget.memory,
                      onRequestExpand: () => unawaited(_ensureAskHalf()),
                      onRequestStepUp: () =>
                          unawaited(_setAskLevel(stepAskSheetUp(_askLevel))),
                      onRequestCollapse: () => unawaited(_collapseAskSheet()),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _OpeningSkeleton extends StatelessWidget {
  const _OpeningSkeleton({
    required this.palette,
    required this.title,
    required this.hint,
    required this.padding,
  });

  final ReaderPalette palette;
  final String title;
  final String hint;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final bar = palette.ink.withValues(alpha: 0.08);
    return Padding(
      padding: padding,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              height: 1.35,
              color: palette.ink,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            hint,
            style: TextStyle(fontSize: 13, color: palette.muted),
          ),
          const SizedBox(height: 22),
          for (final width in const [1.0, 0.92, 0.97, 0.74, 0.9, 0.86, 0.95, 0.62])
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: FractionallySizedBox(
                widthFactor: width,
                child: Container(
                  height: 12,
                  decoration: BoxDecoration(
                    color: bar,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
