import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

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
      setState(() => _library = library);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(StaticFileItem file) async {
    final raw = file.downloadUrl.trim();
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
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 24),
        itemCount: files.length,
        separatorBuilder: (context, index) => const WxHairline(),
        itemBuilder: (context, index) {
          final file = files[index];
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 4),
            title: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              '${file.path} · ${_formatBytes(file.size)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.download_outlined, size: 20),
            onTap: () => _open(file),
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
