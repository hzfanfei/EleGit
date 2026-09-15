import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';

typedef OpenUrl = Future<void> Function(Uri uri);

enum _LoginPhase { opening, waiting, error }

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.api,
    required this.onReady,
    this.error = '',
    this.openUrl,
  });

  final WenxiangApi api;
  final Future<void> Function() onReady;
  final String error;
  final OpenUrl? openUrl;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  _LoginPhase _phase = _LoginPhase.opening;
  Object? _error;
  Timer? _poll;
  Timer? _staleTimer;
  bool _stale = false;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    if (widget.error.isNotEmpty) {
      _error = widget.error;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  Future<void> _openBrowser(Uri uri) async {
    if (widget.openUrl != null) {
      await widget.openUrl!(uri);
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  Future<void> _start() async {
    _poll?.cancel();
    _staleTimer?.cancel();
    setState(() {
      _started = true;
      _stale = false;
      _phase = _LoginPhase.opening;
      _error = widget.error.isNotEmpty ? widget.error : null;
    });
    try {
      final started = await widget.api.startOAuth();
      final uri = Uri.parse(started.authorizeUrl);
      await _openBrowser(uri);
      if (!mounted) return;
      setState(() => _phase = _LoginPhase.waiting);
      _staleTimer = Timer(const Duration(seconds: 90), () {
        if (mounted) setState(() => _stale = true);
      });
      _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
        try {
          final done = await widget.api.pollOAuth(started.state);
          if (done) {
            _poll?.cancel();
            _staleTimer?.cancel();
            await widget.onReady();
          }
        } catch (err) {
          _poll?.cancel();
          _staleTimer?.cancel();
          if (mounted) {
            setState(() {
              _phase = _LoginPhase.error;
              _error = err;
            });
          }
        }
      });
    } catch (err) {
      if (mounted) {
        setState(() {
          _phase = _LoginPhase.error;
          _error = err;
        });
      }
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _staleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _phase == _LoginPhase.waiting;
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: Wx.pagePadding,
              children: [
                const SizedBox(height: 20),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: WxMark(size: 40),
                ),
                const SizedBox(height: 22),
                Text('问象', style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 10),
                Text(
                  '打开即用本机仓库问进度。接下来会在浏览器登录 GitHub。',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: Wx.muted,
                        height: 1.55,
                      ),
                ),
                const SizedBox(height: 28),
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: Wx.surface,
                    borderRadius: BorderRadius.circular(Wx.radius),
                    border: Border.all(color: Wx.hairline),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _StepLine(
                          index: '1',
                          label: _phase == _LoginPhase.opening ? '正在打开浏览器' : '已打开浏览器',
                          active: _phase == _LoginPhase.opening,
                          done: waiting || _phase == _LoginPhase.error,
                        ),
                        const SizedBox(height: 14),
                        _StepLine(
                          index: '2',
                          label: waiting ? '等待授权' : '在浏览器完成授权',
                          active: waiting,
                          done: false,
                        ),
                        const SizedBox(height: 16),
                        if (waiting || _phase == _LoginPhase.opening)
                          const ClipRRect(
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        const SizedBox(height: 14),
                        Text(
                          waiting
                              ? '请在浏览器完成 GitHub 授权，然后回到这里。'
                              : _phase == _LoginPhase.opening
                                  ? '正在打开 GitHub…'
                                  : '授权没有完成。可以重新打开 GitHub。',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Wx.text,
                                height: 1.5,
                              ),
                        ),
                        if (_stale && waiting) ...[
                          const SizedBox(height: 10),
                          Text(
                            '还在等授权。若浏览器已关掉，点下面重新打开。',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  WxErrorPanel(error: _error!, onRetry: _start, retryLabel: '重试连接'),
                ],
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: _phase == _LoginPhase.error
                      ? FilledButton(
                          onPressed: _start,
                          child: const Text('重新打开 GitHub'),
                        )
                      : TextButton(
                          onPressed: _started ? _start : null,
                          child: const Text('重新打开 GitHub'),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({
    required this.index,
    required this.label,
    required this.active,
    required this.done,
  });

  final String index;
  final String label;
  final bool active;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final color = active || done ? Wx.text : Wx.muted;
    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? Wx.accent : Wx.raised,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: active ? Wx.accent : Wx.hairline),
          ),
          child: Text(
            done && !active ? '✓' : index,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active ? Wx.onAccent : color,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          label,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: color,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
        ),
      ],
    );
  }
}
