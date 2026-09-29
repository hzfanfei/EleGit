import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../diagnostics/client_error_log.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_edge_back.dart';

class LogCenterPage extends StatefulWidget {
  const LogCenterPage({super.key});

  @override
  State<LogCenterPage> createState() => _LogCenterPageState();
}

class _LogCenterPageState extends State<LogCenterPage> {
  List<Map<String, dynamic>> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    await ClientErrorLog.instance.idle;
    final entries = await ClientErrorLog.instance.listNewest(200);
    if (!mounted) return;
    setState(() {
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _copyAll() async {
    if (_entries.isEmpty) return;
    final text = formatClientLogExport(_entries);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${_entries.length} 条日志')),
    );
  }

  Future<void> _copyOne(Map<String, dynamic> entry) async {
    final text = formatClientLogEntry(entry);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制本条日志')),
    );
  }

  void _openDetail(Map<String, dynamic> entry) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogEntryDetailPage(entry: entry),
      ),
    );
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空日志'),
        content: const Text('将删除本机保存的全部日志记录，且无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('清空')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ClientErrorLog.instance.clear();
    await _reload();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('日志已清空')),
    );
  }

  String _headline(Map<String, dynamic> entry) {
    final summary = entry['summary']?.toString().trim() ?? '';
    if (summary.isNotEmpty) return summary;
    final message = entry['message']?.toString().trim() ?? '';
    if (message.length <= 120) return message;
    return '${message.substring(0, 120)}…';
  }

  String _timeLabel(String? at) {
    if (at == null || at.isEmpty) return '';
    final parsed = DateTime.tryParse(at);
    if (parsed == null) return at;
    final local = parsed.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    final s = local.second.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $h:$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return WxEdgeBack(
      onBack: () => Navigator.of(context).maybePop(),
      child: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WxPageHeader(
              title: '日志中心',
              onBack: () => Navigator.of(context).maybePop(),
              backTooltip: '返回',
              trailing: [
                IconButton(
                  key: const Key('log-center-copy-all'),
                  tooltip: '复制全部',
                  onPressed: _entries.isEmpty ? null : () => unawaited(_copyAll()),
                  icon: const Icon(Icons.copy_all_outlined),
                ),
                IconButton(
                  key: const Key('log-center-clear-all'),
                  tooltip: '清空日志',
                  onPressed: _entries.isEmpty ? null : () => unawaited(_clearAll()),
                  icon: const Icon(Icons.delete_sweep_outlined),
                ),
                IconButton(
                  tooltip: '刷新',
                  onPressed: _loading ? null : () => unawaited(_reload()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const WxHairline(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _loading
                    ? const Center(child: WxLoading(size: 36))
                    : _entries.isEmpty
                        ? Center(
                            child: Text(
                              '暂无日志',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Wx.faint),
                            ),
                          )
                        : RefreshIndicator(
                            onRefresh: _reload,
                            child: ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(Wx.inset, 0, Wx.inset, 24),
                            itemCount: _entries.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (context, index) {
                              final entry = _entries[index];
                              final kind = clientLogKindLabel(entry['kind']?.toString());
                              final synced = entry['synced'] == true;
                              return Material(
                                color: Wx.surface,
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(Wx.radius),
                                  side: const BorderSide(color: Wx.hairline),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: InkWell(
                                  onTap: () => _openDetail(entry),
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
                                    child: Row(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Text(
                                                    kind,
                                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                                          color: Wx.accent,
                                                          fontWeight: FontWeight.w600,
                                                        ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  Text(
                                                    _timeLabel(entry['at']?.toString()),
                                                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                                          color: Wx.faint,
                                                          fontFeatures: const [FontFeature.tabularFigures()],
                                                        ),
                                                  ),
                                                  if (synced) ...[
                                                    const SizedBox(width: 8),
                                                    Text(
                                                      '已同步',
                                                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                                            color: Wx.faint,
                                                          ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                              const SizedBox(height: 6),
                                              Text(
                                                _headline(entry),
                                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                                      height: 1.45,
                                                    ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          tooltip: '复制',
                                          visualDensity: VisualDensity.compact,
                                          onPressed: () => unawaited(_copyOne(entry)),
                                          icon: const Icon(Icons.copy_outlined, size: 20),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              );
                            },
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

class LogEntryDetailPage extends StatelessWidget {
  const LogEntryDetailPage({super.key, required this.entry});

  final Map<String, dynamic> entry;

  Future<void> _copy(BuildContext context) async {
    final text = formatClientLogEntry(entry);
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制本条日志')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kind = clientLogKindLabel(entry['kind']?.toString());
    final body = Theme.of(context).textTheme.bodyMedium?.copyWith(
          height: 1.55,
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Courier', 'monospace'],
        );
    final full = formatClientLogEntry(entry);
    return WxEdgeBack(
      onBack: () => Navigator.of(context).maybePop(),
      child: Scaffold(
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WxPageHeader(
              title: '日志详情',
              subtitle: kind,
              onBack: () => Navigator.of(context).maybePop(),
              backTooltip: '返回',
              trailing: [
                IconButton(
                  tooltip: '复制',
                  onPressed: () => unawaited(_copy(context)),
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
            const WxHairline(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(Wx.inset, 16, Wx.inset, 24),
                child: SelectableText(
                  full,
                  key: const Key('log-entry-detail-body'),
                  style: body,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
