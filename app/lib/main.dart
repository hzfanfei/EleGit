import 'package:flutter/material.dart';

import 'api/wenxiang_api.dart';
import 'config.dart';
import 'models.dart';
import 'screens/chat_page.dart';
import 'screens/login_page.dart';
import 'screens/repos_page.dart';
import 'theme.dart';

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
  String _bootError = '';

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      await _api.ping();
      final status = await _api.status();
      if (!mounted) return;
      setState(() {
        _step = status.githubConnected ? AppStep.repos : AppStep.login;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _bootError = err.toString();
        _step = AppStep.login;
      });
    }
  }

  Future<void> _afterLogin() async {
    await _api.status();
    if (!mounted) return;
    setState(() => _step = AppStep.repos);
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case AppStep.boot:
        return const Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('问象', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
                SizedBox(height: 20),
                CircularProgressIndicator(),
              ],
            ),
          ),
        );
      case AppStep.login:
        return LoginPage(
          api: _api,
          onReady: _afterLogin,
          error: _bootError,
        );
      case AppStep.repos:
        return ReposPage(
          api: _api,
          onOpen: (repo) => setState(() {
            _repo = repo;
            _step = AppStep.chat;
          }),
          onBack: () => setState(() => _step = AppStep.login),
        );
      case AppStep.chat:
        return ChatPage(
          api: _api,
          repo: _repo!,
          onBack: () => setState(() => _step = AppStep.repos),
        );
    }
  }
}
