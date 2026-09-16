import 'package:flutter/material.dart';

import 'api/wenxiang_api.dart';
import 'config.dart';
import 'models.dart';
import 'screens/chat_page.dart';
import 'screens/login_page.dart';
import 'screens/repos_page.dart';
import 'theme.dart';
import 'widgets/wx_chrome.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WenxiangApp());
}

class WenxiangApp extends StatelessWidget {
  const WenxiangApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '问象',
      debugShowCheckedModeBanner: false,
      theme: wenxiangTheme(),
      home: const ShellPage(),
    );
  }
}

enum AppStep { boot, login, repos, chat }

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  AppStep _step = AppStep.boot;
  late final WenxiangApi _api = WenxiangApi(
    baseUrl: AppEnv.publicUrl,
    apiKey: AppEnv.apiKey,
  );
  RepoItem? _repo;
  Object? _bootError;
  bool _booting = true;
  bool _loginAutoStart = true;
  String _githubLogin = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _boot();
    });
  }

  Future<void> _boot() async {
    setState(() {
      _booting = true;
      _bootError = null;
      _step = AppStep.boot;
    });
    try {
      await _api.ping();
      final status = await _api.status();
      if (!mounted) return;
      setState(() {
        _booting = false;
        _githubLogin = status.githubLogin;
        _loginAutoStart = !status.githubConnected;
        _step = status.githubConnected ? AppStep.repos : AppStep.login;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _bootError = err;
        _step = AppStep.boot;
      });
    }
  }

  Future<void> _afterLogin() async {
    final status = await _api.status();
    if (!mounted) return;
    setState(() {
      _githubLogin = status.githubLogin;
      _step = AppStep.repos;
    });
  }

  Widget _page() {
    switch (_step) {
      case AppStep.boot:
        return _BootPane(
          busy: _booting,
          error: _bootError,
          onRetry: _boot,
        );
      case AppStep.login:
        return LoginPage(
          api: _api,
          onReady: _afterLogin,
          autoStart: _loginAutoStart,
        );
      case AppStep.repos:
        return ReposPage(
          api: _api,
          githubLogin: _githubLogin,
          onOpen: (repo) => setState(() {
            _repo = repo;
            _step = AppStep.chat;
          }),
          onBack: () => setState(() {
            _loginAutoStart = false;
            _step = AppStep.login;
          }),
        );
      case AppStep.chat:
        return ChatPage(
          api: _api,
          repo: _repo!,
          onBack: () => setState(() => _step = AppStep.repos),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 320),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.018),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
      },
      child: KeyedSubtree(
        key: ValueKey(_step),
        child: _page(),
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
