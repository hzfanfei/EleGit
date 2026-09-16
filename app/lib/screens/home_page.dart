import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_clone_scrim.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.api,
    required this.onOpen,
    required this.onBrowse,
    required this.onBack,
    this.githubLogin = '',
    this.lastRepo,
    this.recent = const [],
  });

  final WenxiangApi api;
  final void Function(RepoItem repo) onOpen;
  final VoidCallback onBrowse;
  final VoidCallback onBack;
  final String githubLogin;
  final RepoItem? lastRepo;
  final List<RepoItem> recent;

  @override
  State<HomePage> createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  RepoItem? _cloning;
  Object? _cloneError;
  int _cloneAttempt = 0;

  List<RepoItem> get _recentOthers {
    final lastName = widget.lastRepo?.fullName;
    return widget.recent.where((repo) => repo.fullName != lastName).take(4).toList();
  }

  Future<void> openRepo(RepoItem repo) async {
    if (_cloning != null && _cloneError == null) return;
    setState(() {
      _cloning = repo;
      _cloneError = null;
      _cloneAttempt += 1;
    });
    try {
      await widget.api.checkout(repo.owner, repo.name);
      if (!mounted) return;
      HapticFeedback.lightImpact();
      widget.onOpen(repo);
      if (mounted) setState(() => _cloning = null);
    } on OperationCancelled {
      if (mounted) _dismissClone();
    } catch (err) {
      if (!mounted) return;
      setState(() => _cloneError = err);
    }
  }

  bool consumeBack() {
    if (_cloning != null && _cloneError == null) {
      cancelClone();
      return true;
    }
    return false;
  }

  void cancelClone() {
    widget.api.cancelCheckout();
    _dismissClone();
  }

  void _dismissClone() {
    setState(() {
      _cloning = null;
      _cloneError = null;
    });
  }

  @override
  void dispose() {
    if (_cloning != null && _cloneError == null) {
      widget.api.cancelCheckout();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = widget.lastRepo;
    final others = _recentOthers;
    final blocked = _cloning != null && _cloneError == null;
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              WxPageHeader(
                onBack: () {
                  if (!consumeBack()) widget.onBack();
                },
                backTooltip: blocked ? '取消克隆' : '重新登录',
                showMark: true,
                title: '问象',
                subtitle: widget.githubLogin.isEmpty ? '已授权的仓库' : widget.githubLogin,
              ),
              const WxHairline(),
              Expanded(
                child: ListView(
                  padding: Wx.pagePadding,
                  children: [
                    Text(
                      last != null ? '继续上次' : '从仓库问起',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      last != null
                          ? '点一下打开对话。本机还没有这份仓库时，会先落到 ~/问象。'
                          : '已经授权。选一个仓库，或去全部仓库里找。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 22),
                    if (last != null)
                      _HomeRepoCard(
                        key: const Key('wx-home-last'),
                        repo: last,
                        primary: true,
                        enabled: !blocked,
                        onTap: () => openRepo(last),
                      )
                    else if (others.isEmpty)
                      const WxEmpty(
                        title: '还没有最近用过的仓库',
                        detail: '去全部仓库里打开一个，下次会记在这里。',
                      ),
                    if (others.isNotEmpty) ...[
                      const SizedBox(height: 28),
                      Text('最近', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 10),
                      for (final repo in others) ...[
                        _HomeRepoCard(
                          repo: repo,
                          enabled: !blocked,
                          onTap: () => openRepo(repo),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],
                    const SizedBox(height: 20),
                    TextButton(
                      onPressed: blocked ? null : widget.onBrowse,
                      child: const Text('全部仓库'),
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (_cloning != null)
            WxCloneScrim(
              key: ValueKey(_cloneAttempt),
              repo: _cloning!,
              error: _cloneError,
              onRetry: _cloneError == null ? null : () => openRepo(_cloning!),
              onDismiss: _cloneError == null ? cancelClone : _dismissClone,
              dismissLabel: _cloneError == null ? '取消' : '关闭',
            ),
        ],
      ),
    );
  }
}

class _HomeRepoCard extends StatelessWidget {
  const _HomeRepoCard({
    super.key,
    required this.repo,
    required this.onTap,
    required this.enabled,
    this.primary = false,
  });

  final RepoItem repo;
  final VoidCallback onTap;
  final bool enabled;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary ? Wx.raised : Wx.surface,
      borderRadius: BorderRadius.circular(Wx.radius),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(Wx.radius),
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Wx.radius),
            border: Border.all(color: primary ? Wx.accent.withValues(alpha: 0.45) : Wx.hairline),
          ),
          child: Padding(
            padding: EdgeInsets.fromLTRB(primary ? 18 : 14, primary ? 18 : 14, 14, primary ? 18 : 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        repo.fullName,
                        style: primary
                            ? Theme.of(context).textTheme.titleLarge
                            : Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        primary ? '打开对话' : [repo.language, if (repo.privateRepo) '私有'].where((p) => p.isNotEmpty).join(' · '),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                Icon(
                  primary ? Icons.north_east : Icons.chevron_right,
                  size: primary ? 18 : 20,
                  color: primary ? Wx.accent : Wx.faint,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
