import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/wenxiang_api.dart';
import '../api/temporary_project_api.dart';
import '../chat/running_sessions.dart';
import '../models.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_speak_answer.dart';
import 'chat_page.dart';

/// Same project chat page, with a disposable workspace and no persistent memory.
class TemporaryChatPage extends StatefulWidget {
  const TemporaryChatPage({super.key, required this.api, required this.onBack});
  final WenxiangApi api;
  final VoidCallback onBack;
  @override
  State<TemporaryChatPage> createState() => _TemporaryChatPageState();
}

class _TemporaryChatPageState extends State<TemporaryChatPage> {
  late final _api = TemporaryProjectApi(widget.api);
  late final _repo = RepoItem(
      owner: '__wenxiang_temporary__',
      name: '临时目录',
      fullName: '临时会话',
      description: '',
      privateRepo: true,
      language: '',
      pushedAt: '');
  bool _closing = false;
  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    RunningSessions.of(_api).discard();
    try {
      await AnswerSpeech.shared.stop(_api);
    } finally {
      await _api.closeProject();
    }
  }

  void _back() {
    unawaited(_close());
    widget.onBack();
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }

  Future<void> _files() async {
    final id = _api.activeId;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('临时会话还没准备好，请先新建会话')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) =>
          _TemporaryFilesSheet(api: widget.api, sessionId: id),
    );
  }

  @override
  Widget build(BuildContext context) => ChatPage(
      api: _api,
      repo: _repo,
      temporary: true,
      onBack: _back,
      onOpenFiles: _files);
}

class _TemporaryFilesSheet extends StatefulWidget {
  const _TemporaryFilesSheet({required this.api, required this.sessionId});

  final WenxiangApi api;
  final String sessionId;

  @override
  State<_TemporaryFilesSheet> createState() => _TemporaryFilesSheetState();
}

class _TemporaryFilesSheetState extends State<_TemporaryFilesSheet> {
  late Future<Map<String, dynamic>> _request = _load();

  Future<Map<String, dynamic>> _load() =>
      widget.api.temporaryChatRequest(widget.sessionId);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<Map<String, dynamic>>(
        future: _request,
        builder: (context, snapshot) {
          final data = snapshot.data;
          final files =
              (data?['files'] as List? ?? const []).whereType<Map>().toList();
          return ListView.builder(
            shrinkWrap: true,
            itemCount: 1 + (files.isEmpty ? 1 : files.length),
            itemBuilder: (context, index) {
              if (index == 0) {
                return const ListTile(
                  title: Text('本次生成文件'),
                  subtitle: Text('已归档的文件可在静态资源区继续打开。'),
                );
              }
              if (snapshot.connectionState != ConnectionState.done) {
                return const ListTile(title: WxInlineBusy('正在读取生成文件…'));
              }
              if (snapshot.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: WxErrorPanel(
                    error: snapshot.error!,
                    onRetry: () => setState(() => _request = _load()),
                  ),
                );
              }
              if (files.isEmpty) return const ListTile(title: Text('暂无生成文件'));
              return _fileTile(files[index - 1], '${data?['downloadKey']}');
            },
          );
        },
      ),
    );
  }

  Widget _fileTile(Map file, String downloadKey) {
    final path = '${file['path']}';
    final onlineUrl = file['downloadUrl'] as String?;
    final uri = onlineUrl == null
        ? widget.api.temporaryFileUri(widget.sessionId, path, downloadKey)
        : Uri.parse(onlineUrl);
    return ListTile(
      leading: const Icon(Icons.download_outlined),
      title: Text(path),
      subtitle: onlineUrl == null ? const Text('临时下载，退出前有效') : null,
      onTap: () => launchUrl(uri, mode: LaunchMode.externalApplication),
    );
  }
}
