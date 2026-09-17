import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/wenxiang_api.dart';
import '../config.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';
import 'chat_page.dart';
import 'repos_page.dart';

enum AppStep { boot, repos, chat }

class ShellPage extends StatefulWidget {
  const ShellPage({super.key, this.api, this.memory});

  final WenxiangApi? api;
  final AppMemory? memory;

  @override
  State<ShellPage> createState() => ShellPageState();
}

class ShellPageState extends State<ShellPage> {
  AppStep _step = AppStep.boot;
  late final WenxiangApi _api = widget.api ??
      WenxiangApi(
        baseUrl: AppEnv.publicUrl,
        apiKey: AppEnv.apiKey,
      );
  AppMemory? _memory;
  RepoItem? _repo;
  RepoItem? _lastRepo;
  Object? _bootError;
  bool _booting = true;
  String _githubLogin = '';
  bool _githubConnected = false;
  bool _oauthAutoStart = false;
  final _reposKey = GlobalKey<ReposPageState>();

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
    _lastRepo = _memory?.lastRepo();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _boot();
    });
  }

  Future<AppMemory?> _ensureMemory() async {
    final existing = _memory;
    if (existing != null) return existing;
    try {
      final prefs = await SharedPreferences.getInstance();
      final created = AppMemory(prefs);
      _memory = created;
      return created;
    } catch (_) {
      return null;
    }
  }

  Future<void> _boot() async {
    setState(() {
      _booting = true;
      _bootError = null;
      _step = AppStep.boot;
    });
    try {
      final memory = await _ensureMemory();
      await _api.ping();
      final status = await _api.status();
      if (!mounted) return;
      setState(() {
        _booting = false;
        _githubConnected = status.githubConnected;
        _githubLogin = status.githubLogin.isNotEmpty ? status.githubLogin : (memory?.githubLogin() ?? '');
        _oauthAutoStart = !status.githubConnected;
        _lastRepo = memory?.lastRepo() ?? _lastRepo;
        _step = AppStep.repos;
      });
      if (status.githubLogin.isNotEmpty) {
        await memory?.saveGithubLogin(status.githubLogin);
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _bootError = err;
        _step = AppStep.boot;
      });
    }
  }

  Future<void> _onAuthorized() async {
    final status = await _api.status();
    final memory = await _ensureMemory();
    if (status.githubLogin.isNotEmpty) {
      await memory?.saveGithubLogin(status.githubLogin);
    }
    if (!mounted) return;
    setState(() {
      _githubConnected = status.githubConnected;
      _githubLogin = status.githubLogin;
      _oauthAutoStart = false;
    });
    _reposKey.currentState?.reload();
  }

  void _openRepo(RepoItem repo) {
    _memory?.saveLastRepo(repo);
    _api.warmChatSession(repo.owner, repo.name).catchError((_) {});
    setState(() {
      _repo = repo;
      _step = AppStep.chat;
    });
  }

  void _backFromChat() {
    _api.cancelChat();
    setState(() {
      _step = AppStep.repos;
      _lastRepo = _memory?.lastRepo();
    });
  }

  bool _handlePop() {
    if (_step == AppStep.chat) {
      _backFromChat();
      return true;
    }
    if (_step == AppStep.repos) {
      if (_reposKey.currentState?.consumeBack() == true) return true;
    }
    return false;
  }

  Widget _fit(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = MediaQuery.sizeOf(context);
        return SizedBox(
          width: constraints.maxWidth.isFinite ? constraints.maxWidth : size.width,
          height: constraints.maxHeight.isFinite ? constraints.maxHeight : size.height,
          child: child,
        );
      },
    );
  }

  List<Page<void>> _pages() {
    if (_step == AppStep.boot) {
      return [
        MaterialPage<void>(
          key: const ValueKey('boot'),
          name: 'boot',
          child: _fit(_BootPane(
            busy: _booting,
            error: _bootError,
            onRetry: _boot,
          )),
        ),
      ];
    }
    return [
      MaterialPage<void>(
        key: ValueKey('repos-$_githubConnected-$_githubLogin'),
        name: 'repos',
        child: _fit(ReposPage(
          key: _reposKey,
          api: _api,
          githubConnected: _githubConnected,
          githubLogin: _githubLogin,
          autoStartOAuth: _oauthAutoStart,
          lastRepo: _lastRepo,
          onAuthorized: _onAuthorized,
          onOpen: _openRepo,
        )),
      ),
      if (_step == AppStep.chat && _repo != null)
        MaterialPage<void>(
          key: ValueKey('chat-${_repo!.fullName}'),
          name: 'chat',
          child: _fit(ChatPage(
            api: _api,
            repo: _repo!,
            memory: _memory,
            onBack: _backFromChat,
          )),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == AppStep.boot || _step == AppStep.repos,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handlePop();
      },
      child: SizedBox.expand(
        child: Navigator(
          pages: _pages(),
          onDidRemovePage: (page) {
            final name = page.name;
            if (name == 'chat' && _step == AppStep.chat) {
              _backFromChat();
            }
          },
        ),
      ),
    );
  }
}

class _BootPane extends StatelessWidget {
  const _BootPane({
    required this.busy,
    required this.error,
    required this.onRetry,
  });

  final bool busy;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: Wx.pagePadding,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const WxMark(size: 44),
                  const SizedBox(height: 22),
                  Text('问象', style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: 10),
                  Text(
                    busy
                        ? '正在连接本机服务'
                        : (error == null ? '打开即问本机仓库进度。' : ''),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 28),
                  if (busy)
                    const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else if (error != null)
                    WxErrorPanel(error: error!, onRetry: onRetry),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
