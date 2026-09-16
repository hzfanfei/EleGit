import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/wenxiang_api.dart';
import '../config.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../theme.dart';
import '../widgets/wx_chrome.dart';
import 'chat_page.dart';
import 'home_page.dart';
import 'login_page.dart';
import 'repos_page.dart';

enum AppStep { boot, login, home, repos, chat }

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
  List<RepoItem> _recent = const [];
  Object? _bootError;
  bool _booting = true;
  bool _loginAutoStart = true;
  int _loginGen = 0;
  String _githubLogin = '';
  AppStep _afterChat = AppStep.home;
  final _homeKey = GlobalKey<HomePageState>();
  final _reposKey = GlobalKey<ReposPageState>();

  @override
  void initState() {
    super.initState();
    _memory = widget.memory;
    _lastRepo = _memory?.lastRepo();
    _recent = _memory?.recentRepos() ?? const [];
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
        _githubLogin = status.githubLogin.isNotEmpty ? status.githubLogin : (memory?.githubLogin() ?? '');
        _loginAutoStart = !status.githubConnected;
        _lastRepo = memory?.lastRepo();
        _recent = memory?.recentRepos() ?? const [];
        _step = status.githubConnected ? AppStep.home : AppStep.login;
      });
      if (status.githubLogin.isNotEmpty) {
        await memory?.saveGithubLogin(status.githubLogin);
      }
      if (status.githubConnected) {
        await _refreshRecent();
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

  Future<void> _refreshRecent() async {
    try {
      final list = await _api.repos('');
      await _memory?.rememberRepos(list);
      if (!mounted) return;
      setState(() {
        _lastRepo = _memory?.lastRepo() ?? _lastRepo;
        _recent = _memory?.recentRepos().isNotEmpty == true ? _memory!.recentRepos() : list;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _recent = _memory?.recentRepos() ?? _recent;
      });
    }
  }

  Future<void> _afterLogin() async {
    final status = await _api.status();
    final memory = await _ensureMemory();
    if (status.githubLogin.isNotEmpty) {
      await memory?.saveGithubLogin(status.githubLogin);
    }
    if (!mounted) return;
    setState(() {
      _githubLogin = status.githubLogin;
      _step = AppStep.home;
    });
    await _refreshRecent();
  }

  void _openRepo(RepoItem repo, {required AppStep from}) {
    _memory?.saveLastRepo(repo);
    setState(() {
      _lastRepo = repo;
      _recent = _memory?.recentRepos() ?? _recent;
      _repo = repo;
      _afterChat = from;
      _step = AppStep.chat;
    });
  }

  void _backToHome() {
    _api.cancelChat();
    setState(() => _step = AppStep.home);
  }

  void _backToRepos() {
    _api.cancelChat();
    setState(() => _step = AppStep.repos);
  }

  void _backFromChat() {
    if (_afterChat == AppStep.repos) {
      _backToRepos();
    } else {
      _backToHome();
    }
  }

  void _backToLogin() {
    setState(() {
      _loginAutoStart = false;
      _loginGen += 1;
      _step = AppStep.login;
    });
  }

  bool _handlePop() {
    if (_step == AppStep.chat) {
      _backFromChat();
      return true;
    }
    if (_step == AppStep.repos) {
      if (_reposKey.currentState?.consumeBack() == true) return true;
      _backToHome();
      return true;
    }
    if (_step == AppStep.home) {
      if (_homeKey.currentState?.consumeBack() == true) return true;
      _backToLogin();
      return true;
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
        key: ValueKey('login-$_loginGen'),
        name: 'login',
        child: _fit(LoginPage(
          api: _api,
          onReady: _afterLogin,
          autoStart: _loginAutoStart,
        )),
      ),
      if (_step == AppStep.home || _step == AppStep.repos || _step == AppStep.chat)
        MaterialPage<void>(
          key: const ValueKey('home'),
          name: 'home',
          child: _fit(HomePage(
            key: _homeKey,
            api: _api,
            githubLogin: _githubLogin,
            lastRepo: _lastRepo,
            recent: _recent,
            onOpen: (repo) => _openRepo(repo, from: AppStep.home),
            onBrowse: () => setState(() => _step = AppStep.repos),
            onBack: _backToLogin,
          )),
        ),
      if (_step == AppStep.repos || (_step == AppStep.chat && _afterChat == AppStep.repos))
        MaterialPage<void>(
          key: const ValueKey('repos'),
          name: 'repos',
          child: _fit(ReposPage(
            key: _reposKey,
            api: _api,
            githubLogin: _githubLogin,
            onOpen: (repo) => _openRepo(repo, from: AppStep.repos),
            onBack: _backToHome,
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
      canPop: _step == AppStep.login || _step == AppStep.boot,
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
          } else if (name == 'repos' && (_step == AppStep.repos || _step == AppStep.chat)) {
            _backToHome();
          } else if (name == 'home' && _step != AppStep.login && _step != AppStep.boot) {
            _backToLogin();
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
