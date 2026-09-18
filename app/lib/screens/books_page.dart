import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';
import '../persist/book_local.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';

class BooksPage extends StatefulWidget {
  const BooksPage({
    super.key,
    required this.api,
    required this.bookStore,
    required this.onBack,
    required this.onAsk,
  });

  final WenxiangApi api;
  final BookLocalStore bookStore;
  final VoidCallback onBack;
  final void Function(BookItem book) onAsk;

  @override
  State<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<BooksPage> {
  List<BookItem> _books = [];
  Object? _error;
  bool _loading = true;
  String? _downloadingId;
  double? _downloadProgress;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final books = await widget.api.listBooks();
      if (!mounted) return;
      setState(() => _books = books);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download(BookItem book) async {
    if (_downloadingId != null) return;
    HapticFeedback.lightImpact();
    setState(() {
      _downloadingId = book.id;
      _downloadProgress = null;
    });
    try {
      final dest = await BookLocalStore.targetPath(book.id, book.filename);
      await widget.api.downloadBookFile(
        book.id,
        dest,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _downloadProgress = total == null || total <= 0 ? null : received / total;
          });
        },
      );
      await widget.bookStore.remember(book.id, dest);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已下载《${book.title}》')),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err.toString())),
      );
    } finally {
      if (mounted) {
        setState(() {
          _downloadingId = null;
          _downloadProgress = null;
        });
      }
    }
  }

  Future<void> _openLocal(BookItem book) async {
    final path = widget.bookStore.localPath(book.id);
    if (path == null) {
      await _download(book);
      return;
    }
    final result = await OpenFilex.open(path);
    if (!mounted) return;
    if (result.type != ResultType.done) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(result.message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            showMark: false,
            title: '问书',
            subtitle: '本机 EPUB 库',
            onBack: widget.onBack,
            backTooltip: '返回问仓',
            trailing: [
              IconButton(
                tooltip: '刷新',
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh, size: 20),
              ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          const WxHairline(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 16, Wx.inset, 0),
              child: WxErrorPanel(error: _error!, onRetry: _load),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _books.isEmpty) {
      return const WxBusy(label: '正在读取书单');
    }
    if (_books.isEmpty) {
      return WxEmpty(
        title: '还没有 EPUB',
        detail: '在本机问象 workspace 的 books 目录放入 .epub 文件，然后下拉刷新。',
        action: TextButton(onPressed: _load, child: const Text('重新加载')),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 24),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        itemCount: _books.length,
        itemBuilder: (context, index) {
          final book = _books[index];
          final local = widget.bookStore.localPath(book.id);
          final downloading = _downloadingId == book.id;
          return _BookCard(
            api: widget.api,
            book: book,
            downloaded: local != null,
            downloading: downloading,
            progress: downloading ? _downloadProgress : null,
            onDownload: () => _download(book),
            onOpen: () => _openLocal(book),
            onAsk: () => widget.onAsk(book),
          );
        },
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    required this.api,
    required this.book,
    required this.downloaded,
    required this.downloading,
    required this.progress,
    required this.onDownload,
    required this.onOpen,
    required this.onAsk,
  });

  final WenxiangApi api;
  final BookItem book;
  final bool downloaded;
  final bool downloading;
  final double? progress;
  final VoidCallback onDownload;
  final VoidCallback onOpen;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Wx.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onAsk,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      _cover(),
                      if (downloading)
                        ColoredBox(
                          color: Colors.black45,
                          child: Center(
                            child: SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(
                                value: progress,
                                strokeWidth: 2.5,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              if (book.author.isNotEmpty)
                Text(
                  book.author,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: Wx.faint),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    tooltip: downloaded ? '打开' : '下载',
                    visualDensity: VisualDensity.compact,
                    onPressed: downloading ? null : (downloaded ? onOpen : onDownload),
                    icon: Icon(downloaded ? Icons.menu_book_outlined : Icons.download_outlined, size: 18),
                  ),
                  IconButton(
                    tooltip: '问书',
                    visualDensity: VisualDensity.compact,
                    onPressed: downloading ? null : onAsk,
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                  ),
                  if (downloaded)
                    const Padding(
                      padding: EdgeInsets.only(left: 4),
                      child: Icon(Icons.offline_pin, size: 16, color: Wx.accent),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _cover() {
    if (book.hasCover) {
      return Image.network(
        api.bookCoverUri(book.id).toString(),
        headers: api.headers,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _placeholder(),
        loadingBuilder: (context, child, progress) {
          if (progress == null) return child;
          return _placeholder();
        },
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return ColoredBox(
      color: Wx.hairline,
      child: Center(
        child: Icon(Icons.auto_stories_outlined, size: 36, color: Wx.faint.withValues(alpha: 0.8)),
      ),
    );
  }
}
