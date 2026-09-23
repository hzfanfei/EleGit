import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/time.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';
import '../repo_open.dart';
import '../widgets/wx_clone_scrim.dart';
import 'login_page.dart';

class ReposPage extends StatefulWidget {
  const ReposPage({
    super.key,
    required this.api,
    required this.onOpen,
    required this.onAuthorized,
    this.onOpenBooks,
    this.onOpenFiles,
    this.onOpenSettings,
    this.githubConnected = true,
    this.githubLogin = '',
    this.autoStartOAuth = false,
    this.lastRepo,
  });

  final WenxiangApi api;
  final void Function(RepoItem repo) onOpen;
  final Future<void> Function() onAuthorized;
  final VoidCallback? onOpenBooks;
  final VoidCallback? onOpenFiles;
  final VoidCallback? onOpenSettings;
  final bool githubConnected;
  final String githubLogin;
  final bool autoStartOAuth;
  final RepoItem? lastRepo;

  @override
  State<ReposPage> createState() => ReposPageState();
}

class ReposPageState extends State<ReposPage> {
  final _query = TextEditingController();
  List<RepoItem> _repos = [];
  bool _localOnly = false;
  RepoItem? _cloning;
  WxCloneMode _cloneMode = WxCloneMode.clone;
  Object? _cloneError;
  int _cloneAttempt = 0;
  bool _loading = true;
  bool _reauth = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _query.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadRepos();
    });
  }

  void _onQueryChanged() {
    if (mounted) setState(() {});
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 450), () {
      if (mounted) _loadRepos();
    });
  }

  @override
  void didUpdateWidget(covariant ReposPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.githubConnected && !oldWidget.githubConnected) {
      _reauth = false;
      _loadRepos();
    }
  }

  void reload() {
    _loadRepos();
  }

  Future<void> _loadRepos() async {
    final query = _query.text.trim();
    setState(() {
      _loading = true;
    });
    try {
      List<RepoItem> repos;
      var localOnly = !widget.githubConnected;
      if (widget.githubConnected) {
        try {
          repos = await widget.api.repos(query);
          localOnly = false;
        } catch (_) {
          repos = await widget.api.localRepos(query);
          localOnly = true;
        }
      } else {
        repos = await widget.api.localRepos(query);
      }
      if (!mounted) return;
      setState(() {
        _repos = repos;
        _localOnly = localOnly;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _repos = [];
        _localOnly = true;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(RepoItem repo) async {
    if (_cloning != null && _cloneError == null) return;
    HapticFeedback.lightImpact();
    setState(() {
      _cloneError = null;
      _cloning = repo;
      _cloneMode = WxCloneMode.open;
      _cloneAttempt += 1;
    });
    try {
      await openRepoWithSync(
        api: widget.api,
        repo: repo,
        onScrim: (mode) {
          if (!mounted) return;
          setState(() {
            _cloning = repo;
            _cloneMode = mode;
            _cloneAttempt += 1;
          });
        },
        onReady: () async {
          if (!mounted) return;
          HapticFeedback.lightImpact();
          widget.onOpen(repo);
        },
      );
      if (mounted) {
        setState(() {
          _cloning = null;
          _cloneError = null;
        });
      }
    } on OperationCancelled {
      if (mounted) _dismissClone();
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _cloneError = err;
        _cloning ??= repo;
        _cloneAttempt += 1;
      });
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
    _debounce?.cancel();
    if (_cloning != null && _cloneError == null) {
      widget.api.cancelCheckout();
    }
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reauth) {
      return LoginPage(
        api: widget.api,
        onReady: () async {
          await widget.onAuthorized();
          if (mounted) setState(() => _reauth = false);
        },
        autoStart: widget.autoStartOAuth && !widget.githubConnected,
        reauth: _reauth,
        onCancel: () => setState(() => _reauth = false),
      );
    }

    final blocked = _cloning != null && _cloneError == null;
    final subtitle = widget.githubConnected
        ? (widget.githubLogin.isEmpty ? '选一个仓库问进度' : widget.githubLogin)
        : (_localOnly ? '本机 ~/问象 仓库' : '选一个仓库问进度');
    return Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            showMark: true,
            title: '问象',
            subtitle: subtitle,
            onBrandTap: blocked ? null : widget.onOpenSettings,
            trailing: [
              if (widget.onOpenFiles != null)
                IconButton(
                  tooltip: '资源',
                  onPressed: blocked ? null : widget.onOpenFiles,
                  icon: const Icon(Icons.folder_outlined),
                ),
              if (widget.onOpenBooks != null)
                IconButton(
                  tooltip: '问书',
                  onPressed: blocked ? null : widget.onOpenBooks,
                  icon: const Icon(Icons.menu_book_outlined),
                ),
              TextButton(
                onPressed: blocked ? null : () => setState(() => _reauth = true),
                child: Text(widget.githubConnected ? 'GitHub' : '连接 GitHub'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(Wx.inset, 4, Wx.inset, 12),
            child: TextField(
              controller: _query,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _loadRepos(),
              enabled: !blocked,
              decoration: InputDecoration(
                hintText: _localOnly ? '搜索本机仓库' : '搜索仓库名',
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
                                _loadRepos();
                              },
                      ),
              ),
            ),
          ),
          if (_loading)
            const LinearProgressIndicator(minHeight: 2),
          const WxHairline(),
          Expanded(
            child: Stack(
              children: [
                _body(),
                if (_cloning != null)
                  WxCloneScrim(
                    key: ValueKey(_cloneAttempt),
                    repo: _cloning!,
                    mode: _cloneMode,
                    error: _cloneError,
                    onRetry: _cloneError == null ? null : () => _open(_cloning!),
                    onDismiss: _cloneError == null ? cancelClone : _dismissClone,
                    dismissLabel: _cloneError == null ? '取消' : '关闭',
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
    if (_repos.isEmpty) {
      final query = _query.text.trim();
      return WxEmpty(
        title: query.isEmpty ? '本机还没有仓库' : '没有找到仓库',
        detail: query.isEmpty
            ? (widget.githubConnected
                ? '把仓库克隆到 ~/问象/<owner>/<repo>，或连接 GitHub 搜索远程。'
                : '把已有 git 仓库放到 ~/问象/<owner>/<repo>，或点「连接 GitHub」。')
            : '换个关键词，或清空搜索看看全部。',
        action: TextButton(onPressed: _loadRepos, child: const Text('重新加载')),
      );
    }
    final query = _query.text.trim();
    final last = widget.lastRepo;
    final showContinue = query.isEmpty && last != null && last.fullName.isNotEmpty;
    return RefreshIndicator(
      onRefresh: _loadRepos,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 24),
        itemCount: _repos.length + (showContinue ? 1 : 0),
        separatorBuilder: (_, __) => const SizedBox(height: 2),
        itemBuilder: (context, index) {
          if (showContinue && index == 0) {
            return _ContinueRepoCard(
              repo: last,
              enabled: _cloning == null,
              onOpen: () => _open(last),
            );
          }
          final repo = _repos[index - (showContinue ? 1 : 0)];
          return _RepoTile(
            repo: repo,
            enabled: _cloning == null,
            onTap: () => _open(repo),
          );
        },
      ),
    );
  }
}

class _ContinueRepoCard extends StatelessWidget {
  const _ContinueRepoCard({
    required this.repo,
    required this.enabled,
    required this.onOpen,
  });

  final RepoItem repo;
  final bool enabled;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Wx.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Wx.radius),
          side: const BorderSide(color: Wx.hairline),
        ),
        child: InkWell(
          key: const Key('wx-home-last'),
          onTap: enabled ? onOpen : null,
          borderRadius: BorderRadius.circular(Wx.radius),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '继续上次',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Wx.muted),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        repo.fullName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: enabled ? onOpen : null,
                  child: const Text('打开对话'),
                ),
              ],
            ),
          ),
        ),
      ),
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
