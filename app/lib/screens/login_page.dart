import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/wenxiang_api.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.api,
    required this.onReady,
    this.error = '',
  });

  final WenxiangApi api;
  final Future<void> Function() onReady;
  final String error;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  String _message = '正在打开 GitHub…';
  Timer? _poll;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    if (_started) return;
    _started = true;
    try {
      final started = await widget.api.startOAuth();
      final uri = Uri.parse(started.authorizeUrl);
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      setState(() => _message = '请在浏览器完成 GitHub 授权，然后回到这里。');
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          final done = await widget.api.pollOAuth(started.state);
          if (done) {
            _poll?.cancel();
            await widget.onReady();
          }
        } catch (err) {
          _poll?.cancel();
          if (mounted) setState(() => _message = err.toString());
        }
      });
    } catch (err) {
      if (mounted) setState(() => _message = err.toString());
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 24),
              const Text('问象', style: TextStyle(fontSize: 36, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              const Text('用这台电脑上的仓库回答进度。', style: TextStyle(height: 1.45)),
              const SizedBox(height: 36),
              const LinearProgressIndicator(minHeight: 2),
              const SizedBox(height: 20),
              SelectableText(_message, style: const TextStyle(height: 1.45)),
              if (widget.error.isNotEmpty) ...[
                const SizedBox(height: 12),
                SelectableText(widget.error),
              ],
              const Spacer(),
              TextButton(onPressed: () {
                _started = false;
                _start();
              }, child: const Text('重新打开 GitHub')),
            ],
          ),
        ),
      ),
    );
  }
}
