import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../diagnostics/client_error_log.dart';
import '../diagnostics/log_center_merge.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_edge_back.dart';

class LogCenterPage extends StatefulWidget {
  const LogCenterPage({super.key, this.api, this.onBack});

  final WenxiangApi? api;
  final VoidCallback? onBack;

  @override
  State<LogCenterPage> createState() => _LogCenterPageState();
}

class _LogCenterPageState extends State<LogCenterPage> {
  List<Map<String, dynamic>> _entries = const [];
  bool _loading = true;
  Object? _loadError;
  String? _remoteHint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      await ClientErrorLog.instance.idle;
      final local = await ClientErrorLog.instance.peek(200);
      var remote = const <Map<String, dynamic>>[];
      String? remoteHint;
      final api = widget.api;
      if (api != null) {
        try {
          remote = await api.fetchErrorLogs(limit: 200);
        } catch (err) {
          remoteHint = '服务端日志拉取失败，仅显示本机记录。';
        }
      }
      if (!mounted) return;
      setState(() {
        _remoteHint = remoteHint;
        _entries = mergeLogCenterEntries(local: local, remote: remote, limit: 200);
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _loadError = err);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmClear() async {
    if (_entries.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('将清空本机与服务端已保存的错误日志（含语音识别、合成等记录）。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ClientErrorLog.instance.clear();
    final api = widget.api;
    if (api != null) {
      try {
        await api.clearErrorLogs();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('本机已清空，但服务端日志清空失败，刷新后可能仍会出现。')),
          );
        }
      }
    }
    await _reload();
  }

  void _openEntry(Map<String, dynamic> entry) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Wx.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Wx.radius)),
      ),
      builder: (ctx) {
        final message = entry['message']?.toString() ?? '';
        final summary = entry['summary']?.toString() ?? '';
        final stack = entry['stack']?.toString() ?? '';
        final at = _formatAt(entry['at']?.toString());
        final kind = clientLogKindLabel(entry['kind']?.toString());
        final scope = logScopeLabel(entry);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.72,
          minChildSize: 0.4,
          maxChildSize: 0.92,
          builder: (context, scrollController) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Wx.hairline,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Text('日志详情', style: Theme.of(context).textTheme.titleMedium),
                      ),
                      IconButton(
                        tooltip: '复制',
                        onPressed: () {
                          final text = [
                            if (at.isNotEmpty) at,
                            kind,
                            if (summary.isNotEmpty) summary,
                            message,
                            if (stack.isNotEmpty) stack,
                          ].join('\n\n');
                          Clipboard.setData(ClipboardData(text: text));
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('已复制到剪贴板')),
                          );
                        },
                        icon: const Icon(Icons.copy_rounded, size: 20),
                      ),
                    ],
                  ),
                  if (at.isNotEmpty) ...[
                    Text(at, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint)),
                    const SizedBox(height: 6),
                  ],
                  Text(
                    [kind, scope].join(' · '),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.muted),
                  ),
                  const SizedBox(height: 14),
                  Expanded(
                    child: ListView(
                      controller: scrollController,
                      children: [
                        if (summary.isNotEmpty) ...[
                          Text('摘要', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint)),
                          const SizedBox(height: 4),
                          SelectableText(summary, style: Theme.of(context).textTheme.bodyMedium),
                          const SizedBox(height: 16),
                        ],
                        Text('原文', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint)),
                        const SizedBox(height: 4),
                        SelectableText(
                          message,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                fontFamilyFallback: const ['Courier', 'monospace'],
                              ),
                        ),
                        if (stack.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text('堆栈', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint)),
                          const SizedBox(height: 4),
                          SelectableText(
                            stack,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  fontFamily: 'monospace',
                                  fontFamilyFallback: const ['Courier', 'monospace'],
                                  color: Wx.muted,
                                ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return WxEdgeBack(
      onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
      child: Scaffold(
        body: Column(
          children: [
            WxPageHeader(
              title: '日志中心',
              onBack: widget.onBack ?? () => Navigator.of(context).maybePop(),
              backTooltip: '返回',
              trailing: [
                IconButton(
                  tooltip: '刷新',
                  onPressed: _loading ? null : () => unawaited(_reload()),
                  icon: const Icon(Icons.refresh_rounded, size: 22),
                ),
                IconButton(
                  tooltip: '清空',
                  onPressed: _entries.isEmpty || _loading ? null : () => unawaited(_confirmClear()),
                  icon: const Icon(Icons.delete_outline_rounded, size: 22),
                ),
              ],
            ),
            const WxHairline(),
            Expanded(child: _body(context)),
          ],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading && _entries.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Wx.inset),
          child: Text('加载失败：$_loadError', style: Theme.of(context).textTheme.bodyMedium),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Wx.inset),
          child: Text(
            '暂无错误记录。本机与服务端（含语音识别、合成等第三方调用）的错误会汇总在这里。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Wx.muted),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Wx.inset, 12, Wx.inset, 32),
        itemCount: _entries.length + (_remoteHint != null ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          if (_remoteHint != null && index == 0) {
            return Text(
              _remoteHint!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.danger),
            );
          }
          final entry = _entries[index - (_remoteHint != null ? 1 : 0)];
          return _LogEntryTile(entry: entry, onTap: () => _openEntry(entry));
        },
      ),
    );
  }
}

class _LogEntryTile extends StatelessWidget {
  const _LogEntryTile({required this.entry, required this.onTap});

  final Map<String, dynamic> entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final summary = entry['summary']?.toString().trim() ?? '';
    final message = entry['message']?.toString().trim() ?? '';
    final title = summary.isNotEmpty ? summary : message;
    final subtitle = summary.isNotEmpty && message != summary ? message : null;
    final at = _formatAt(entry['at']?.toString());
    final kind = clientLogKindLabel(entry['kind']?.toString());
    final scope = logScopeLabel(entry);

    return Material(
      color: Wx.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Wx.radius),
        side: const BorderSide(color: Wx.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title.isEmpty ? '（无内容）' : title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Wx.muted),
                      ),
                    ],
                    const SizedBox(height: 6),
                    Text(
                      [if (at.isNotEmpty) at, kind, scope].join(' · '),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.faint),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Wx.faint, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

String clientLogKindLabel(String? kind) {
  switch (kind) {
    case 'shown':
      return '界面提示';
    case 'flutter':
      return 'Flutter';
    case 'platform':
      return '平台';
    case 'chat':
      return '问答';
    case 'voice-asr':
      return '语音识别';
    case 'voice-tts':
      return '语音合成';
    case 'voice-turn':
      return '语音问答';
    default:
      return kind == null || kind.isEmpty ? '错误' : kind;
  }
}

String _formatAt(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final parsed = DateTime.tryParse(iso);
  if (parsed == null) return iso;
  final local = parsed.toLocal();
  final two = (int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}
