import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  DeviceStart? _device;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    _pat.dispose();
    super.dispose();
  }

  Future<void> _savePat() async {
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await widget.api.savePat(_pat.text.trim());
      await widget.onChanged();
      setState(() => _message = 'GitHub 已连接。');
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
                ? '已登录 ${widget.status.githubLogin}。Token 保存在电脑 ~/.wenxiang/，不经过云端模型服务。'
                : '推荐使用 Personal Access Token（需要 repo 读权限）。若本机配置了 GitHub OAuth App，也可以用设备码。',
            style: const TextStyle(height: 1.45),
          ),
          const SizedBox(height: 20),
          if (!connected) ...[
            TextField(
              controller: _pat,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'GitHub PAT',
                hintText: 'ghp_… 或 github_pat_…',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _savePat,
              child: const Text('保存并验证'),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : _startDevice,
              child: const Text('使用设备码登录'),
            ),
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
