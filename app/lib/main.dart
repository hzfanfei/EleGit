import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api/wenxiang_api.dart';
import 'models.dart';
import 'screens/chat_page.dart';
import 'screens/connect_page.dart';
import 'screens/repos_page.dart';
import 'screens/setup_page.dart';
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

enum AppStep { setup, github, repos, chat }

class ShellPage extends StatefulWidget {
  const ShellPage({super.key});

  @override
  State<ShellPage> createState() => _ShellPageState();
}

class _ShellPageState extends State<ShellPage> {
  AppStep _step = AppStep.setup;
  WenxiangApi? _api;
  ServerStatus? _status;
  RepoItem? _repo;

  Future<bool> _hydrate() async {
    final prefs = await SharedPreferences.getInstance();
    final url = (prefs.getString('baseUrl') ?? '').trim();
    final key = (prefs.getString('apiKey') ?? '').trim();
    if (url.isEmpty || key.isEmpty) return false;
    final api = WenxiangApi(baseUrl: url, apiKey: key);
    try {
      await api.ping();
      final status = await api.status();
      setState(() {
        _api = api;
        _status = status;
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _afterSetup() async {
    final ok = await _hydrate();
    if (ok) setState(() => _step = AppStep.github);
  }

  Future<void> _refreshStatus() async {
    if (_api == null) return;
    final status = await _api!.status();
    setState(() => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    switch (_step) {
      case AppStep.setup:
        return SetupPage(onReady: _afterSetup);
      case AppStep.github:
        return ConnectPage(
          api: _api!,
          status: _status!,
          onChanged: _refreshStatus,
          onContinue: () => setState(() => _step = AppStep.repos),
          onBack: () => setState(() => _step = AppStep.setup),
        );
      case AppStep.repos:
        return ReposPage(
          api: _api!,
          onOpen: (repo) => setState(() {
            _repo = repo;
            _step = AppStep.chat;
          }),
          onBack: () => setState(() => _step = AppStep.github),
        );
      case AppStep.chat:
        return ChatPage(
          api: _api!,
          repo: _repo!,
          onBack: () => setState(() => _step = AppStep.repos),
        );
    }
  }
}
