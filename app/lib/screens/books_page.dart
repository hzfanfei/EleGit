import 'package:flutter/material.dart';
import '../api/wenxiang_api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';

class BooksPage extends StatefulWidget {
  const BooksPage({
    super.key,
    required this.api,
    required this.onBack,
    required this.onRead,
    this.opening = false,
  });

  final WenxiangApi api;
  final VoidCallback onBack;
  final Future<void> Function(BookItem book, {bool expandAsk}) onRead;
  final bool opening;

  @override
  State<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<BooksPage> {
  List<BookItem> _books = [];
  Object? _error;
  bool _loading = true;

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

  Future<void> _read(BookItem book, {bool expandAsk = false}) async {
    if (widget.opening) return;
    await widget.onRead(book, expandAsk: expandAsk);
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
          return _BookCard(
            api: widget.api,
            book: book,
            onRead: () => _read(book),
            onAsk: () => _read(book, expandAsk: true),
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
    required this.onRead,
    required this.onAsk,
  });

  final WenxiangApi api;
  final BookItem book;
  final VoidCallback onRead;
  final VoidCallback onAsk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Wx.surface,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onRead,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _cover(),
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
                    tooltip: '阅读',
                    visualDensity: VisualDensity.compact,
                    onPressed: onRead,
                    icon: const Icon(Icons.menu_book_outlined, size: 18),
                  ),
                  IconButton(
                    tooltip: '边读边问',
                    visualDensity: VisualDensity.compact,
                    onPressed: onAsk,
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
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
