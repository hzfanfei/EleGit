import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/wenxiang_api.dart';
import '../copy/ask_engine.dart';
import '../models.dart';

class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.onReady});

  final Future<void> Function() onReady;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  String _message = '';
  ServerStatus? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _url.text = prefs.getString('baseUrl') ?? 'http://192.168.1.10:8787';
    _key.text = prefs.getString('apiKey') ?? '';
    setState(() {});
  }

  Future<void> _saveAndTest() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('baseUrl', _url.text.trim());
      await prefs.setString('apiKey', _key.text.trim());
      final api = WenxiangApi(baseUrl: _url.text.trim(), apiKey: _key.text.trim());
      await api.ping();
      final status = await api.status();
      setState(() {
        _status = status;
        _message = '已连上本机问象服务。';
      });
    } catch (err) {
      setState(() {
        _status = null;
        _message = err.toString();
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleTunnel(bool start) async {
    setState(() => _busy = true);
    try {
      final api = WenxiangApi(baseUrl: _url.text.trim(), apiKey: _key.text.trim());
      if (start) {
        await api.startTunnel();
      } else {
        await api.stopTunnel();
      }
      final status = await api.status();
      setState(() {
        _status = status;
        _message = start
            ? (status.tunnelUrl.isEmpty
                ? '隧道已启动，正在等待公网 URL… 稍后点「测试连接」刷新。'
                : '隧道 URL：${status.tunnelUrl}')
            : '隧道已停止。局域网地址仍可用。';
      });
    } catch (err) {
      setState(() => _message = err.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('问象 · 连接本机')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '手机只访问这台电脑上的问象服务。同一 Wi-Fi 填局域网地址；不在同一网则先在电脑启动 Cloudflare 隧道。',
            style: TextStyle(height: 1.45),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: '服务地址',
              hintText: 'http://192.168.1.10:8787',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _key,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: '电脑启动服务时打印的密钥',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _saveAndTest,
            child: Text(_busy ? '连接中…' : '测试连接'),
          ),
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 16),
            SelectableText(_message),
          ],
          if (_status != null) ...[
            const SizedBox(height: 20),
            _StatusCard(status: _status!),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _toggleTunnel(true),
                    child: const Text('启动隧道'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : () => _toggleTunnel(false),
                    child: const Text('停止隧道'),
                  ),
                ),
              ],
            ),
            if (_status!.tunnelUrl.isNotEmpty) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _status!.tunnelUrl));
                  _url.text = _status!.tunnelUrl;
                },
                child: const Text('用隧道地址填入服务地址'),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton.tonal(
              onPressed: widget.onReady,
              child: const Text('下一步：连接 GitHub'),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});
  final ServerStatus status;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(status.githubConnected
                ? 'GitHub：已登录 ${status.githubLogin}'
                : status.oauthReady
                    ? 'GitHub：未连接（可用浏览器登录）'
                    : 'GitHub：未连接（本机尚未配置 OAuth App）'),
            if (status.workspaceRoot.isNotEmpty)
              Text('工作区：${status.workspaceRoot}'),
            Text(
              status.cursorAvailable
                  ? '智能问答：已就绪（${askEngineChoiceLabel(parseAskEngineChoice(status.askEnginePreference))}）'
                  : '智能问答：仅本地进度摘要',
            ),
            Text(
              status.tunnelRunning
                  ? '隧道：运行中 ${status.tunnelUrl.isEmpty ? "（等待 URL）" : status.tunnelUrl}'
                  : '隧道：未启动',
            ),
            if (status.tunnelError.isNotEmpty) Text('隧道：${status.tunnelError}'),
            if (status.lanUrls.isNotEmpty)
              Text('局域网：${status.lanUrls.join("  ")}'),
          ],
        ),
      ),
    );
  }
}
