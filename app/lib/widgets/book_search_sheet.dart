import 'package:flutter/material.dart';

import '../api/wenxiang_api.dart';
import '../screens/annas_browser_page.dart';
import '../theme.dart';
import 'wx_chrome.dart';

/// 是否在安娜的档案浏览器里保存过书。
class BookSearchOutcome {
  BookSearchOutcome({required this.downloaded});
  final bool downloaded;
}

/// 输入关键词后打开安娜的档案内置浏览器（不再聚合其它搜书源）。
class BookSearchSheet extends StatefulWidget {
  const BookSearchSheet({super.key, required this.api});

  final WenxiangApi api;

  @override
  State<BookSearchSheet> createState() => _BookSearchSheetState();
}

class _BookSearchSheetState extends State<BookSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  int _savedCount = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
      setState(() => _savedCount += outcome!.savedCount);
    }
  }

  void _closeWithResult() {
    Navigator.of(context).pop(BookSearchOutcome(downloaded: _savedCount > 0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.42,
      minChildSize: 0.32,
      maxChildSize: 0.55,
      builder: (context, scrollController) {
        return SafeArea(
          child: Column(
            children: [
              _handle(),
              Padding(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 4, Wx.inset, 8),
                child: Text(
                  '安娜的档案',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 0, Wx.inset, 12),
                child: Text(
                  '在内置浏览器里搜索、点下载；问象会拦截 epub 链接并写入本机 books 目录。',
                  style: theme.textTheme.bodySmall?.copyWith(color: Wx.faint),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Wx.inset),
                child: TextField(
                  controller: _controller,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: const InputDecoration(
                    hintText: '书名或作者（可留空）',
                    prefixIcon: Icon(Icons.search, size: 20),
                  ),
                  onSubmitted: (_) => _openAnnasBrowser(),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: Wx.inset),
                child: FilledButton.icon(
                  onPressed: _openAnnasBrowser,
                  icon: const Icon(Icons.travel_explore_outlined, size: 18),
                  label: const Text('打开内置浏览器'),
                ),
              ),
              if (_savedCount > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '本次已保存 $_savedCount 本',
                  style: theme.textTheme.bodySmall?.copyWith(color: Wx.ok),
                ),
              ],
              const Spacer(),
              const WxHairline(),
              Padding(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
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
}
