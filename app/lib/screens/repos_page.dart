import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../copy/time.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_link_route.dart';
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
  String _workspaceRoot = '';
  String _checkoutPath = '';
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
    widget.api.linkEpoch.addListener(_onLinkChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _loadWorkspace();
      _loadRepos();
    });
  }

  void _onLinkChanged() {
    if (mounted) setState(() {});
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

  Future<void> _loadWorkspace() async {
    try {
      final status = await widget.api.status();
      if (!mounted) return;
      setState(() => _workspaceRoot = status.workspaceRoot);
    } catch (_) {}
  }

  String _pathFor(RepoItem repo) {
    final root = _workspaceRoot.trim();
    if (root.isEmpty) return '${repo.owner}/${repo.name}';
    final sep = root.contains('\\') ? '\\' : '/';
    final base = root.replaceAll(RegExp(r'[/\\]+$'), '');
    return '$base$sep${repo.owner}$sep${repo.name}';
  }

  Future<void> _open(RepoItem repo) async {
    if (_cloning != null && _cloneError == null) return;
    HapticFeedback.lightImpact();
    setState(() {
      _cloneError = null;
      _cloning = repo;
      _checkoutPath = _pathFor(repo);
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
        onPath: (path) {
          if (!mounted || path.isEmpty) return;
          setState(() => _checkoutPath = path);
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

  Future<void> _createRepo() async {
    if (_cloning != null && _cloneError == null) return;
    HapticFeedback.lightImpact();
    if (!widget.githubConnected) {
      setState(() => _reauth = true);
      return;
    }
    final created = await showModalBottomSheet<RepoItem>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Wx.surface,
      builder: (context) => _NewRepoSheet(api: widget.api),
    );
    if (created == null || !mounted) return;
    setState(() {
      _repos = [
        created,
        ..._repos.where((repo) => repo.fullName != created.fullName),
      ];
    });
    await _open(created);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_cloning != null && _cloneError == null) {
      widget.api.cancelCheckout();
    }
    widget.api.linkEpoch.removeListener(_onLinkChanged);
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
    final home = widget.githubConnected
        ? (widget.githubLogin.isEmpty ? '选一个仓库问进度' : widget.githubLogin)
        : (_localOnly
            ? (_workspaceRoot.isEmpty ? '本机仓库' : _workspaceRoot)
            : '选一个仓库问进度');
    final subtitle = home;
    return Scaffold(
      body: Column(
        children: [
          WxPageHeader(
            showMark: true,
            title: '问象',
            subtitle: subtitle,
            status: WxLinkQualityMark(api: widget.api),
            onBrandTap: blocked ? null : widget.onOpenSettings,
            trailing: [
              IconButton(
                key: const Key('wx-home-new-repo'),
                tooltip: '新建仓库',
                onPressed: blocked ? null : _createRepo,
                icon: const Icon(Icons.add),
              ),
              if (widget.onOpenFiles != null)
                IconButton(
                  key: const Key('wx-home-files'),
                  tooltip: '资源',
                  onPressed: blocked ? null : widget.onOpenFiles,
                  icon: const Icon(Icons.folder_outlined),
                ),
              if (widget.onOpenBooks != null)
                IconButton(
                  key: const Key('wx-home-books'),
                  tooltip: '问书',
                  onPressed: blocked ? null : widget.onOpenBooks,
                  icon: const Icon(Icons.menu_book_outlined),
                ),
              PopupMenuButton<String>(
                key: const Key('wx-home-more'),
                tooltip: '更多',
                enabled: !blocked,
                color: Wx.surface,
                surfaceTintColor: Colors.transparent,
                icon: const Icon(Icons.more_horiz),
                onSelected: (value) {
                  if (value == 'github') setState(() => _reauth = true);
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'github',
                    child: Text(widget.githubConnected ? 'GitHub' : '连接 GitHub'),
                  ),
                ],
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
                    path: _checkoutPath,
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
                ? '把仓库克隆到 ${_workspaceRoot.isEmpty ? '本机工作区' : _workspaceRoot}/<owner>/<repo>，或连接 GitHub 搜索远程。'
                : '把已有 git 仓库放到 ${_workspaceRoot.isEmpty ? '本机工作区' : _workspaceRoot}/<owner>/<repo>，或点「连接 GitHub」。')
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

class _NewRepoSheet extends StatefulWidget {
  const _NewRepoSheet({required this.api});

  final WenxiangApi api;

  @override
  State<_NewRepoSheet> createState() => _NewRepoSheetState();
}

class _NewRepoSheetState extends State<_NewRepoSheet> {
  final _name = TextEditingController();
  final _description = TextEditingController();
  bool _private = true;
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  String? _nameError(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return '请填写仓库名';
    final bad = name.length > 100 ||
        name.startsWith('.') ||
        name.startsWith('-') ||
        name.endsWith('.') ||
        name.contains('..') ||
        name.toLowerCase().endsWith('.git') ||
        RegExp(r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])$', caseSensitive: false).hasMatch(name) ||
        RegExp(r'[\s\\/?#%*:|"<>]').hasMatch(name);
    if (bad) return '仓库名请用字母、数字或中文，可加点、下划线和连字符';
    return null;
  }

  Future<void> _submit() async {
    final nameError = _nameError(_name.text);
    final description = _description.text.trim();
    if (nameError != null) {
      setState(() => _error = nameError);
      return;
    }
    if (description.length > 350) {
      setState(() => _error = '简介最多 350 个字');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final repo = await widget.api.createRepo(
        name: _name.text.trim(),
        description: description,
        privateRepo: _private,
      );
      if (!mounted) return;
      Navigator.pop(context, repo);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = err.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(Wx.inset, 8, Wx.inset, 16 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Text('在 GitHub 新建', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            '建在当前登录的账号下，带一份 README。建好后拉到本机打开。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Wx.muted),
          ),
          const SizedBox(height: 16),
          TextField(
            key: const Key('wx-new-repo-name'),
            controller: _name,
            enabled: !_busy,
            autofocus: true,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(hintText: '仓库名'),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('wx-new-repo-description'),
            controller: _description,
            enabled: !_busy,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: const InputDecoration(hintText: '简介，可选'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('私有仓库'),
            value: _private,
            onChanged: _busy ? null : (value) => setState(() => _private = value),
          ),
          if (_error.isNotEmpty) ...[
            Text(_error, style: const TextStyle(color: Wx.danger, height: 1.35)),
            const SizedBox(height: 8),
          ],
          FilledButton(
            key: const Key('wx-new-repo-submit'),
            onPressed: _busy ? null : _submit,
            child: Text(_busy ? '正在创建' : '创建'),
          ),
        ],
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
        borderRadius: BorderRadius.circular(Wx.radius),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 12, 0, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Wx.raised,
                    borderRadius: BorderRadius.circular(4),
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
