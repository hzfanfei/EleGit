import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/time.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';

class ReposPage extends StatefulWidget {
  const ReposPage({
    super.key,
    required this.api,
    required this.onOpen,
    required this.onBack,
    this.githubLogin = '',
  });

  final WenxiangApi api;
  final void Function(RepoItem repo) onOpen;
  final VoidCallback onBack;
  final String githubLogin;

  @override
  State<ReposPage> createState() => _ReposPageState();
}

class _ReposPageState extends State<ReposPage> {
  final _query = TextEditingController();
  List<RepoItem> _repos = [];
  Object? _error;
  RepoItem? _cloning;
  Object? _cloneError;
  int _cloneAttempt = 0;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _query.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _search();
    });
  }

  Future<void> _search() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repos = await widget.api.repos(_query.text.trim());
      if (!mounted) return;
      setState(() => _repos = repos);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(RepoItem repo) async {
    if (_cloning != null && _cloneError == null) return;
    setState(() {
      _cloning = repo;
      _cloneError = null;
      _cloneAttempt += 1;
      _error = null;
    });
    try {
      await widget.api.checkout(repo.owner, repo.name);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      widget.onOpen(repo);
    } catch (err) {
      if (!mounted) return;
      setState(() => _cloneError = err);
    } finally {
      if (mounted && _cloneError == null) {
        setState(() => _cloning = null);
      }
    }
  }

  void _dismissClone() {
    setState(() {
      _cloning = null;
      _cloneError = null;
    });
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final blocked = _cloning != null;
    return Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            onBack: widget.onBack,
            backEnabled: !blocked,
            backTooltip: '重新登录',
            showMark: true,
            title: '仓库',
            subtitle: widget.githubLogin.isEmpty
                ? '点进一个，问进度'
                : widget.githubLogin,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Wx.inset, 4, Wx.inset, 12),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              enabled: !blocked,
              decoration: InputDecoration(
                hintText: '搜索仓库名',
                prefixIcon: const Icon(Icons.search, size: 20, color: Wx.faint),
                suffixIcon: _query.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除',
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: blocked
                            ? null
                            : () {
                                _query.clear();
                                _search();
                              },
                      ),
              ),
            ),
          ),
          const WxHairline(),
          if (_error != null && _cloning == null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Wx.inset, 16, Wx.inset, 0),
              child: WxErrorPanel(error: _error!, onRetry: _search),
            ),
          Expanded(
            child: Stack(
              children: [
                _body(),
                if (_cloning != null)
                  _CloneScrim(
                    key: ValueKey(_cloneAttempt),
                    repo: _cloning!,
                    error: _cloneError,
                    onRetry: _cloneError == null ? null : () => _open(_cloning!),
                    onDismiss: _cloneError == null ? null : _dismissClone,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _repos.isEmpty) {
      return const WxBusy(label: '正在读取仓库');
    }
    if (_error != null && _repos.isEmpty) {
      return const SizedBox.shrink();
    }
    if (_repos.isEmpty) {
      return WxEmpty(
        title: '没有找到仓库',
        detail: '换个关键词，或清空搜索看看全部。',
        action: TextButton(onPressed: _search, child: const Text('重新加载')),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 24),
      itemCount: _repos.length,
      separatorBuilder: (_, __) => const SizedBox(height: 2),
      itemBuilder: (context, index) {
        final repo = _repos[index];
        return _RepoTile(
          repo: repo,
          enabled: _cloning == null,
          onTap: () => _open(repo),
        );
      },
    );
  }
}

class _RepoTile extends StatelessWidget {
  const _RepoTile({
    required this.repo,
    required this.enabled,
    required this.onTap,
  });

  final RepoItem repo;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final initial = repo.name.isNotEmpty ? repo.name.substring(0, 1).toUpperCase() : '?';
    final time = formatRelativeTime(repo.pushedAt);
    final meta = [
      repo.owner,
      if (repo.language.isNotEmpty) repo.language,
      if (time.isNotEmpty) time,
    ].join(' · ');
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 0, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Wx.raised,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Wx.hairline),
                  ),
                  child: Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Wx.text,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              repo.name,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          if (repo.privateRepo)
                            Container(
                              margin: const EdgeInsets.only(left: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                border: Border.all(color: Wx.hairline),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '私有',
                                style: TextStyle(fontSize: 11, color: Wx.muted, height: 1.2),
                              ),
                            ),
                        ],
                      ),
                      if (meta.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(meta, style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right, size: 20, color: Wx.faint),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CloneScrim extends StatefulWidget {
  const _CloneScrim({
    super.key,
    required this.repo,
    this.error,
    this.onRetry,
    this.onDismiss,
  });

  final RepoItem repo;
  final Object? error;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  @override
  State<_CloneScrim> createState() => _CloneScrimState();
}

class _CloneScrimState extends State<_CloneScrim> {
  static const _stages = ['准备', '正在克隆', '即将打开'];
  int _stage = 0;
  Timer? _timer;

  String get _path => '~/问象/${widget.repo.owner}/${widget.repo.name}';

  String get _stageDetail {
    switch (_stage) {
      case 0:
        return '先确认 ${widget.repo.fullName}，再落到本机。';
      case 1:
        return '正在克隆到 $_path';
      default:
        return '马上打开这份仓库。';
    }
  }

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 900), (timer) {
      if (!mounted || widget.error != null) return;
      if (_stage < _stages.length - 1) {
        setState(() => _stage += 1);
      }
    });
  }

  @override
  void didUpdateWidget(covariant _CloneScrim oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.error != null) {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final failed = widget.error != null;
    return ColoredBox(
      color: const Color(0xCC0C0D0F),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Wx.surface,
              borderRadius: BorderRadius.circular(Wx.radius),
              border: Border.all(color: Wx.hairline),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failed ? '没有落到本机' : _stages[_stage],
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    failed ? '${widget.repo.fullName} 还没有写到本机。' : _stageDetail,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.5),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _path,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (!failed) ...[
                    const SizedBox(height: 18),
                    const ClipRRect(
                      child: LinearProgressIndicator(minHeight: 2),
                    ),
                  ],
                  if (failed) ...[
                    const SizedBox(height: 16),
                    WxErrorPanel(
                      error: widget.error!,
                      onRetry: widget.onRetry,
                      retryLabel: '再试一次',
                    ),
                    if (widget.onDismiss != null)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: widget.onDismiss,
                          child: const Text('关闭'),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
