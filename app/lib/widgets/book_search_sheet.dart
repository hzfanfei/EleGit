import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';
import '../screens/annas_browser_page.dart';
import '../theme.dart';
import 'wx_chrome.dart';

/// 搜索结果是否触发了至少一次下载的标记。
/// BooksPage 据此决定下完是否要 _load() 刷新书单。
class BookSearchOutcome {
  BookSearchOutcome({required this.downloaded});
  final bool downloaded;
}

/// 从问书页面弹起的底部搜索面板：聚合多个源搜 epub，结果点下载直接落到本机 books 目录。
class BookSearchSheet extends StatefulWidget {
  const BookSearchSheet({super.key, required this.api});

  final WenxiangApi api;

  @override
  State<BookSearchSheet> createState() => _BookSearchSheetState();
}

class _BookSearchSheetState extends State<BookSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  Timer? _debounce;
  String _activeQuery = '';
  bool _searching = false;
  Object? _error;
  List<BookSearchResult> _results = [];
  // 每条结果的下发状态：idle / busy / done / failed
  final Map<String, _DownloadState> _downloadStates = {};
  int _doneCount = 0;

  static const _debounceDuration = Duration(milliseconds: 450);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    _debounce?.cancel();
    final value = _controller.text.trim();
    if (value == _activeQuery) return;
    if (value.isEmpty) {
      setState(() {
        _activeQuery = '';
        _results = [];
        _error = null;
        _searching = false;
      });
      return;
    }
    _debounce = Timer(_debounceDuration, () => _runSearch(value));
  }

  Future<void> _runSearch(String value) async {
    setState(() {
      _searching = true;
      _error = null;
      _activeQuery = value;
      _results = [];
      _downloadStates.clear();
      _doneCount = 0;
    });
    try {
      final results = await widget.api.searchBooks(value, limit: 10);
      if (!mounted) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err;
        _searching = false;
      });
    }
  }

  String _resultKey(BookSearchResult r) {
    if (r.downloadUrl.isNotEmpty) return r.downloadUrl;
    return r.detailUrl ?? r.title;
  }

  Future<void> _openAnnasBrowser() async {
    final query = _controller.text.trim();
    final outcome = await Navigator.of(context).push<AnnasBrowserOutcome>(
      MaterialPageRoute(
        builder: (_) => AnnasBrowserPage(
          api: widget.api,
          initialQuery: query.isEmpty ? null : query,
        ),
      ),
    );
    if (!mounted) return;
    if ((outcome?.savedCount ?? 0) > 0) {
      setState(() => _doneCount += outcome!.savedCount);
    }
  }

  Future<void> _openExternal(BookSearchResult r) async {
    final url = r.detailUrl;
    if (url == null || url.isEmpty) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开链接')),
      );
    }
  }

  Future<void> _download(BookSearchResult r) async {
    final key = _resultKey(r);
    setState(() => _downloadStates[key] = _DownloadState.busy);
    try {
      await widget.api.downloadBook(url: r.downloadUrl, title: r.title);
      if (!mounted) return;
      setState(() {
        _downloadStates[key] = _DownloadState.done;
        _doneCount += 1;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _downloadStates[key] = _DownloadState.failed);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('下载失败：$err')),
      );
    }
  }

  void _closeWithResult() {
    Navigator.of(context).pop(BookSearchOutcome(downloaded: _doneCount > 0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return SafeArea(
          child: Column(
            children: [
              _handle(),
              _searchBar(theme),
              const WxHairline(),
              Expanded(child: _body(scrollController)),
              const WxHairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _doneCount > 0
                            ? '已下载 $_doneCount 本，回到书单查看'
                            : '可搜 Open Library；或点左侧地球在安娜的档案里下载',
                        style: theme.textTheme.bodySmall?.copyWith(color: Wx.faint),
                      ),
                    ),
                    TextButton(
                      onPressed: _closeWithResult,
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _handle() {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6),
      alignment: Alignment.center,
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: Wx.hairline,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _searchBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Wx.inset, 4, Wx.inset, 12),
      child: Row(
        children: [
          IconButton(
            tooltip: '安娜的档案（内置浏览器）',
            onPressed: _openAnnasBrowser,
            icon: const Icon(Icons.travel_explore_outlined, size: 22),
          ),
          Expanded(
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '搜书名或作者',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _controller.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _controller.clear();
                        },
                      ),
              ),
              onSubmitted: (v) {
                _debounce?.cancel();
                _runSearch(v.trim());
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ScrollController scrollController) {
    if (_searching && _results.isEmpty) {
      return const WxBusy(label: '正在搜书');
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 0),
        child: WxErrorPanel(
          error: _error!,
          onRetry: () => _runSearch(_activeQuery),
        ),
      );
    }
    if (_activeQuery.isEmpty) {
      return const WxEmpty(
        title: '输入书名搜索',
        detail: '聚合搜索或点左上角地球，在安娜的档案网页里点下载会自动入库。',
      );
    }
    if (_results.isEmpty) {
      return WxEmpty(
        title: '没有匹配结果',
        detail: '换关键词试试；鸠摩需在服务端 .env 配置 WENXIANG_JIUMO_COOKIE。',
        action: TextButton(
          onPressed: _openAnnasBrowser,
          child: const Text('用浏览器打开安娜的档案'),
        ),
      );
    }
    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 16),
      itemCount: _results.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final r = _results[index];
        return _ResultCard(
          result: r,
          state: _downloadStates[_resultKey(r)] ?? _DownloadState.idle,
          onDownload: () => _download(r),
          onOpen: () => _openExternal(r),
        );
      },
    );
  }
}

enum _DownloadState { idle, busy, done, failed }

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.result,
    required this.state,
    required this.onDownload,
    required this.onOpen,
  });

  final BookSearchResult result;
  final _DownloadState state;
  final VoidCallback onDownload;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Wx.surface,
      borderRadius: BorderRadius.circular(Wx.radius),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    result.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  if (result.author.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      result.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: Wx.faint),
                    ),
                  ],
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _Chip(label: result.sourceLabel.isEmpty ? result.source : result.sourceLabel),
                      if (result.year.isNotEmpty) _Chip(label: result.year),
                      if (result.format.isNotEmpty)
                        _Chip(label: result.format),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            _downloadButton(context, theme),
          ],
        ),
      ),
    );
  }

  Widget _downloadButton(BuildContext context, ThemeData theme) {
    switch (state) {
      case _DownloadState.busy:
        return const SizedBox(
          width: 36,
          height: 36,
          child: Padding(
            padding: EdgeInsets.all(8),
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case _DownloadState.done:
        return Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: Wx.ok.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(18),
          ),
          child: const Icon(Icons.check, size: 20, color: Wx.ok),
        );
      case _DownloadState.failed:
        return IconButton(
          tooltip: '重试下载',
          icon: Icon(Icons.refresh, color: theme.colorScheme.error),
          onPressed: onDownload,
        );
      case _DownloadState.idle:
        if (result.downloadUrl.isEmpty) {
          return FilledButton.tonalIcon(
            onPressed: result.detailUrl == null ? null : onOpen,
            icon: const Icon(Icons.open_in_new, size: 16),
            label: const Text('打开'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            ),
          );
        }
        return FilledButton.tonalIcon(
          onPressed: onDownload,
          icon: const Icon(Icons.download_outlined, size: 16),
          label: const Text('下载'),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
        );
    }
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: Wx.hairline,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint),
      ),
    );
  }
}