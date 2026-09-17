import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/wenxiang_api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';
import '../repo_open.dart';
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
  WxCloneMode _cloneMode = WxCloneMode.clone;
  Object? _cloneError;
  int _cloneAttempt = 0;
  List<RepoItem> _remote = const [];
  Object? _loadError;
  bool _loadingRemote = false;

  List<RepoItem> get _shown {
    final seen = <String>{};
    final out = <RepoItem>[];
    void add(RepoItem? repo) {
      if (repo == null || repo.fullName.isEmpty || seen.contains(repo.fullName)) {
        return;
      }
      seen.add(repo.fullName);
      out.add(repo);
    }

    add(widget.lastRepo);
    for (final repo in widget.recent) {
      add(repo);
    }
    for (final repo in _remote) {
      add(repo);
    }
    return out;
  }

  RepoItem? get _primary => widget.lastRepo ?? (_shown.isEmpty ? null : _shown.first);

  List<RepoItem> get _recentOthers {
    final lastName = _primary?.fullName;
    return _shown.where((repo) => repo.fullName != lastName).take(4).toList();
  }

  @override
  void initState() {
    super.initState();
    if (widget.lastRepo == null && widget.recent.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadRemote();
      });
    }
  }

  @override
  void didUpdateWidget(covariant HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.recent.isNotEmpty || widget.lastRepo != null) {
      return;
    }
    if (_remote.isEmpty && !_loadingRemote && _loadError == null) {
      _loadRemote();
    }
  }

  Future<void> _loadRemote() async {
    setState(() {
      _loadingRemote = true;
      _loadError = null;
    });
    try {
      final list = await widget.api.repos('');
      if (!mounted) return;
      setState(() {
        _remote = list;
        _loadingRemote = false;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loadError = err;
        _loadingRemote = false;
      });
    }
  }

  Future<void> openRepo(RepoItem repo) async {
    if (_cloning != null && _cloneError == null) return;
    setState(() {
      _cloneError = null;
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
    if (_cloning != null && _cloneError == null) {
      widget.api.cancelCheckout();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final last = _primary;
    final others = _recentOthers;
    final blocked = _cloning != null && _cloneError == null;
    final waiting = _loadingRemote && last == null && others.isEmpty;
    return Scaffold(
      body: Stack(
        children: [
          Column(
            children: [
              WxPageHeader(
                onBack: () {
                  if (!consumeBack()) widget.onBack();
                },
                backTooltip: blocked
                    ? (_cloneMode == WxCloneMode.sync ? '取消更新' : '取消克隆')
                    : '重新登录',
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
                      widget.lastRepo != null ? '继续上次' : '从仓库问起',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      last != null
                          ? '点一下打开对话。本机已有且最新则直接进入；落后会先更新；还没有则落到 ~/问象。'
                          : waiting
                              ? '正在读取已授权的仓库…'
                              : '已经授权。选一个仓库，或去全部仓库里找。',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 22),
                    if (waiting)
                      const WxBusy(label: '正在读取仓库')
                    else if (_loadError != null && last == null && others.isEmpty)
                      WxErrorPanel(error: _loadError!, onRetry: _loadRemote)
                    else if (last != null)
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
              mode: _cloneMode,
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
