import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/link_route.dart';
import '../api/wenxiang_api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';

class StaticFilesPage extends StatefulWidget {
  const StaticFilesPage({
    super.key,
    required this.api,
    required this.onBack,
  });

  final WenxiangApi api;
  final VoidCallback onBack;

  @override
  State<StaticFilesPage> createState() => _StaticFilesPageState();
}

class _StaticFilesPageState extends State<StaticFilesPage> {
  StaticLibrary? _library;
  Object? _error;
  bool _loading = true;
  String? _deletingPath;
  bool _batchDeleting = false;
  final _selected = <String>{};

  bool get _busy => _deletingPath != null || _batchDeleting;

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
      final library = await widget.api.listStaticFiles();
      if (!mounted) return;
      final paths = library.files.map((file) => file.path).toSet();
      setState(() {
        _library = library;
        _selected.removeWhere((path) => !paths.contains(path));
      });
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(StaticFileItem file) async {
    final raw = downloadUrlOnBase(file.downloadUrl, widget.api.baseUrl);
    if (raw.isEmpty) return;
    final uri = Uri.tryParse(raw);
    if (uri == null) return;
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('无法打开下载链接')),
      );
    }
  }

  Future<void> _confirmDelete(StaticFileItem file) async {
    if (_busy) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这个资源？'),
        content: Text('${file.name}\n\n删除后无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deletingPath = file.path);
    try {
      await widget.api.deleteStaticFile(file.path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除 ${file.name}')),
      );
      await _load();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err.toString())),
      );
    } finally {
      if (mounted) setState(() => _deletingPath = null);
    }
  }

  void _toggleAll(List<StaticFileItem> files, bool? checked) {
    setState(() {
      if (checked == true) {
        _selected
          ..clear()
          ..addAll(files.map((file) => file.path));
      } else {
        _selected.clear();
      }
    });
  }

  Future<void> _confirmDeleteSelected(List<StaticFileItem> files) async {
    if (_busy || _selected.isEmpty) return;
    final chosen = files.where((file) => _selected.contains(file.path)).toList();
    if (chosen.isEmpty) return;
    final all = chosen.length == files.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(all ? '删除全部 ${chosen.length} 个资源？' : '删除选中的 ${chosen.length} 个资源？'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _batchDeleting = true);
    var failed = 0;
    Object? lastError;
    for (final file in chosen) {
      if (!mounted) return;
      try {
        await widget.api.deleteStaticFile(file.path);
        _selected.remove(file.path);
      } catch (err) {
        failed += 1;
        lastError = err;
      }
    }
    if (!mounted) return;
    final removed = chosen.length - failed;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? '已删除 $removed 个资源'
              : '已删除 $removed 个，${failed} 个没删掉${lastError == null ? '' : '：$lastError'}',
        ),
      ),
    );
    setState(() => _batchDeleting = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final files = _library?.files ?? const <StaticFileItem>[];
    return Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            showMark: false,
            title: '资源',
            subtitle: '图片、安装包和其他静态文件',
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
          Expanded(child: _body(files)),
        ],
      ),
    );
  }

  Widget _body(List<StaticFileItem> files) {
    if (_loading && files.isEmpty) {
      return const WxBusy(label: '正在读取资源');
    }
    if (files.isEmpty) {
      final dir = _library?.dir ?? '';
      return WxEmpty(
        title: '还没有静态资源',
        detail: dir.isEmpty
            ? '把图片、安装包放到本机问象目录的 static 文件夹，然后刷新。'
            : '把图片、安装包放到 $dir ，然后刷新。',
        action: TextButton(onPressed: _load, child: const Text('重新加载')),
      );
    }
    final allSelected = files.every((file) => _selected.contains(file.path));
    final someSelected = _selected.isNotEmpty && !allSelected;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Row(
            children: [
              Checkbox(
                visualDensity: VisualDensity.compact,
                tristate: true,
                value: allSelected ? true : (someSelected ? null : false),
                onChanged: _busy ? null : (_) => _toggleAll(files, !allSelected),
              ),
              GestureDetector(
                onTap: _busy ? null : () => _toggleAll(files, !allSelected),
                child: const Text('全选'),
              ),
              const Spacer(),
              if (_batchDeleting)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: WxLoading(size: 20),
                )
              else
                TextButton(
                  onPressed: _selected.isEmpty || _busy ? null : () => _confirmDeleteSelected(files),
                  style: TextButton.styleFrom(foregroundColor: Wx.danger),
                  child: Text(_selected.isEmpty ? '删除' : '删除 ${_selected.length}'),
                ),
            ],
          ),
        ),
        const WxHairline(),
        Expanded(child: _fileList(files)),
      ],
    );
  }

  Widget _fileList(List<StaticFileItem> files) {
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 24),
        itemCount: files.length,
        separatorBuilder: (context, index) => const WxHairline(),
        itemBuilder: (context, index) {
          final file = files[index];
          final deleting = _deletingPath == file.path;
          final picked = _selected.contains(file.path);
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            leading: Checkbox(
              visualDensity: VisualDensity.compact,
              value: picked,
              onChanged: _busy
                  ? null
                  : (checked) {
                      setState(() {
                        if (checked == true) {
                          _selected.add(file.path);
                        } else {
                          _selected.remove(file.path);
                        }
                      });
                    },
            ),
            title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                file.path,
                _formatBytes(file.size),
                if (_formatMtime(file.mtime) case final t?) t,
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (deleting)
                  const WxLoading(size: 20)
                else
                  IconButton(
                    tooltip: '删除',
                    icon: Icon(Icons.delete_outline, size: 22, color: Wx.danger),
                    onPressed: _busy ? null : () => _confirmDelete(file),
                  ),
                const Icon(Icons.download_outlined, size: 20),
              ],
            ),
            onTap: deleting ? null : () => _open(file),
          );
        },
      ),
    );
  }
}

String _formatBytes(int size) {
  if (size < 1024) return '$size B';
  if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
  return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String? _formatMtime(String? iso) {
  final raw = iso?.trim();
  if (raw == null || raw.isEmpty) return null;
  final dt = DateTime.tryParse(raw);
  if (dt == null) return null;
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}
