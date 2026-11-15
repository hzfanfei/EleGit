import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api/wenxiang_api.dart';
import '../api/temporary_project_api.dart';
import '../chat/running_sessions.dart';
import '../models.dart';
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
    await AnswerSpeech.shared.stop(_api);
    await _api.closeProject();
  }

  Future<void> _back() async {
    await _close();
    if (mounted) widget.onBack();
  }

  @override
  void dispose() {
    unawaited(_close());
    super.dispose();
  }

  Future<void> _files() async {
    final id = _api.activeId;
    if (id == null) return;
    try {
      final data = await widget.api.temporaryChatRequest(id);
      if (!mounted) return;
      final files = (data['files'] as List? ?? []).whereType<Map>();
      await showModalBottomSheet<void>(
          context: context,
          builder: (context) => SafeArea(
                  child: ListView(shrinkWrap: true, children: [
                const ListTile(
                    title: Text('本次生成文件'),
                    subtitle: Text('结束临时会话后删除；已下载到手机的文件由你保留。')),
                if (files.isEmpty) const ListTile(title: Text('暂无生成文件')),
                for (final file in files)
                  ListTile(
                      leading: const Icon(Icons.download_outlined),
                      title: Text('${file['path']}'),
                      onTap: () async {
                        final uri = widget.api.temporaryFileUri(
                            id, '${file['path']}', '${data['downloadKey']}');
                        await launchUrl(uri,
                            mode: LaunchMode.externalApplication);
                      }),
              ])));
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(err.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ChatPage(
      api: _api,
      repo: _repo,
      temporary: true,
      onBack: _back,
      onOpenFiles: _files);
}
