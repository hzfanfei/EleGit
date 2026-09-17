import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api/wenxiang_api.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';

typedef OpenUrl = Future<void> Function(Uri uri);

enum _LoginPhase { idle, opening, waiting, ready, error }

class LoginPage extends StatefulWidget {
  const LoginPage({
    super.key,
    required this.api,
    required this.onReady,
    this.error = '',
    this.openUrl,
    this.autoStart = true,
    this.onCancel,
    this.reauth = false,
  });

  final WenxiangApi api;
  final Future<void> Function() onReady;
  final String error;
  final OpenUrl? openUrl;
  final bool autoStart;
  final VoidCallback? onCancel;
  final bool reauth;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  _LoginPhase _phase = _LoginPhase.idle;
  Object? _error;
  Timer? _poll;
  Timer? _staleTimer;
  bool _stale = false;

  @override
  void initState() {
    super.initState();
    if (widget.error.isNotEmpty) {
      _error = widget.error;
    }
    if (widget.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _start();
      });
    } else {
      _phase = _LoginPhase.idle;
    }
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
          if (!done) return;
          _poll?.cancel();
          _staleTimer?.cancel();
          if (!mounted) return;
          setState(() => _phase = _LoginPhase.ready);
          HapticFeedback.lightImpact();
          await Future<void>.delayed(const Duration(milliseconds: 560));
          if (mounted) await widget.onReady();
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

  String get _bodyCopy {
    switch (_phase) {
      case _LoginPhase.idle:
        return '已从仓库返回。要换 GitHub 账号，再打开一次授权。';
      case _LoginPhase.opening:
        return '正在打开 GitHub…';
      case _LoginPhase.waiting:
        return '请在浏览器完成 GitHub 授权，然后回到这里。';
      case _LoginPhase.ready:
        return '已授权，正在进入仓库…';
      case _LoginPhase.error:
        return '授权没有完成。可以重新打开 GitHub。';
    }
  }

  @override
  Widget build(BuildContext context) {
    final waiting = _phase == _LoginPhase.waiting;
    final ready = _phase == _LoginPhase.ready;
    final opening = _phase == _LoginPhase.opening;
    return Scaffold(
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: ListView(
              padding: Wx.pagePadding,
              children: [
                if (widget.onCancel != null)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      tooltip: '返回仓库',
                      onPressed: widget.onCancel,
                      icon: const Icon(Icons.close),
                    ),
                  )
                else
                  const SizedBox(height: 20),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: WxMark(size: 40),
                ),
                const SizedBox(height: 22),
                Text('问象', style: Theme.of(context).textTheme.displaySmall),
                const SizedBox(height: 10),
                Text(
                  widget.reauth
                      ? '换 GitHub 账号后，会重新读取你有权限的仓库。'
                      : _phase == _LoginPhase.idle
                          ? '已经登录过。只有要换账号时，才需要再走一遍 GitHub。'
                          : '打开即用本机仓库问进度。接下来会在浏览器登录 GitHub。',
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
                    border: Border.all(color: ready ? Wx.ok : Wx.hairline),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _StepLine(
                          index: '1',
                          label: opening
                              ? '正在打开浏览器'
                              : (waiting || ready)
                                  ? '已打开浏览器'
                                  : '打开浏览器',
                          active: opening,
                          done: waiting || ready,
                        ),
                        const SizedBox(height: 14),
                        _StepLine(
                          index: '2',
                          label: ready
                              ? '已授权'
                              : waiting
                                  ? '等待授权'
                                  : '在浏览器完成授权',
                          active: waiting,
                          done: ready,
                        ),
                        if (opening || waiting) ...[
                          const SizedBox(height: 16),
                          const ClipRRect(
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Text(
                          _bodyCopy,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: ready ? Wx.ok : Wx.text,
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
                  child: _phase == _LoginPhase.error || _phase == _LoginPhase.idle
                      ? FilledButton(
                          onPressed: _start,
                          child: const Text('重新打开 GitHub'),
                        )
                      : TextButton(
                          onPressed: ready ? null : _start,
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
            color: active
                ? Wx.accent
                : done
                    ? Wx.ok
                    : Wx.raised,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: active
                  ? Wx.accent
                  : done
                      ? Wx.ok
                      : Wx.hairline,
            ),
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
