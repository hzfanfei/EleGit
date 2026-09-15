import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';

class ConnectPage extends StatefulWidget {
  const ConnectPage({
    super.key,
    required this.api,
    required this.status,
    required this.onChanged,
    required this.onContinue,
    required this.onBack,
  });

  final WenxiangApi api;
  final ServerStatus status;
  final Future<void> Function() onChanged;
  final VoidCallback onContinue;
  final VoidCallback onBack;

  @override
  State<ConnectPage> createState() => _ConnectPageState();
}

class _ConnectPageState extends State<ConnectPage> {
  final _pat = TextEditingController();
  String _message = '';
  bool _busy = false;
  bool _showFallback = false;
  DeviceStart? _device;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    _pat.dispose();
    super.dispose();
  }

  Future<void> _browserLogin() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final started = await widget.api.startOAuth();
      final uri = Uri.parse(started.authorizeUrl);
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) {
        throw ApiException('无法打开系统浏览器，请手动打开：${started.authorizeUrl}');
      }
      setState(() {
        _message =
            '已打开 GitHub。授权完成后回到这里。\n回调必须是：${started.redirectUri}';
      });
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          final done = await widget.api.pollOAuth(started.state);
          if (done) {
            _poll?.cancel();
            await widget.onChanged();
            if (mounted) setState(() => _message = '浏览器登录成功。');
          }
        } catch (err) {
          _poll?.cancel();
          if (mounted) setState(() => _message = err.toString());
        }
      });
    } catch (err) {
      setState(() => _message = err.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _savePat() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await widget.api.savePat(_pat.text.trim());
      await widget.onChanged();
      setState(() => _message = 'GitHub 已连接（PAT 后备）。');
    } catch (err) {
      setState(() => _message = err.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startDevice() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      final device = await widget.api.startDevice();
      setState(() => _device = device);
      _poll?.cancel();
      _poll = Timer.periodic(Duration(seconds: device.interval.clamp(5, 15)), (_) async {
        try {
          final done = await widget.api.pollDevice(device.deviceCode);
          if (done) {
            _poll?.cancel();
            await widget.onChanged();
            if (mounted) setState(() => _message = '设备码登录成功。');
          }
        } catch (err) {
          final text = err.toString();
          if (!text.contains('authorization_pending') && !text.contains('slow_down')) {
            _poll?.cancel();
            if (mounted) setState(() => _message = text);
          }
        }
      });
    } catch (err) {
      setState(() => _message = err.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    await widget.api.disconnectGithub();
    await widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final connected = widget.status.githubConnected;
    return Scaffold(
      appBar: AppBar(
        title: const Text('连接 GitHub'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: widget.onBack,
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            connected
                ? '已登录 ${widget.status.githubLogin}。Token 保存在电脑 ~/.wenxiang/。选仓库后会克隆到 ${widget.status.workspaceRoot.isEmpty ? "~/问象" : widget.status.workspaceRoot}。'
                : widget.status.oauthReady
                    ? '在系统浏览器中登录 GitHub。本机 GitHub OAuth App 的回调必须等于手机里的服务地址 + /oauth/github/callback。'
                    : '本机还没有配置 GitHub OAuth App。在电脑设置 GITHUB_CLIENT_ID / GITHUB_CLIENT_SECRET，并把下列回调登记到 GitHub。',
            style: const TextStyle(height: 1.45),
          ),
          if (!connected && widget.status.callbackUrls.isNotEmpty) ...[
            const SizedBox(height: 12),
            SelectableText(
              widget.status.callbackUrls.join('\n'),
              style: const TextStyle(fontSize: 13, height: 1.4),
            ),
          ],
          const SizedBox(height: 20),
          if (!connected) ...[
            FilledButton(
              onPressed: _busy || !widget.status.oauthReady ? null : _browserLogin,
              child: Text(_busy ? '等待授权…' : '在浏览器中登录 GitHub'),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => setState(() => _showFallback = !_showFallback),
              child: Text(_showFallback ? '收起后备方式' : '使用 PAT 或设备码（后备）'),
            ),
            if (_showFallback) ...[
              TextField(
                controller: _pat,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'GitHub PAT',
                  hintText: 'ghp_… 或 github_pat_…',
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : _savePat,
                child: const Text('保存 PAT'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : _startDevice,
                child: const Text('使用设备码登录'),
              ),
            ],
          ] else ...[
            FilledButton(
              onPressed: widget.onContinue,
              child: const Text('选择仓库'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _disconnect,
              child: const Text('断开 GitHub'),
            ),
          ],
          if (_device != null) ...[
            const SizedBox(height: 20),
            Card(
              child: ListTile(
                title: Text('在浏览器打开 ${_device!.verificationUri}'),
                subtitle: Text('输入代码 ${_device!.userCode}'),
                trailing: IconButton(
                  icon: const Icon(Icons.copy),
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: _device!.userCode)),
                ),
              ),
            ),
          ],
          if (_message.isNotEmpty) ...[
            const SizedBox(height: 16),
            SelectableText(_message),
          ],
        ],
      ),
    );
  }
}
