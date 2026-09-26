import 'dart:async' show unawaited;
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/wenxiang_api.dart';
import '../config.dart';
import '../copy/errors.dart';
import '../diagnostics/client_error_log.dart';
import '../models.dart';
import '../persist/app_memory.dart';
import '../theme.dart';
import '../utils/background_sync.dart';
import '../utils/notification_center.dart';
import '../widgets/wx_chrome.dart';
import '../widgets/wx_edge_back.dart';
import '../widgets/wx_motion.dart';
import 'book_reader_page.dart';
import 'books_page.dart';
import 'chat_page.dart';
import 'repos_page.dart';
import 'settings_page.dart';
import 'static_files_page.dart';

enum AppStep { boot, repos, books, files, chat, bookRead }

class ShellPage extends StatefulWidget {
  const ShellPage({super.key, this.api, this.memory});

  final WenxiangApi? api;
  final AppMemory? memory;

  @override
  State<ShellPage> createState() => ShellPageState();
}

class ShellPageState extends State<ShellPage> with WidgetsBindingObserver {
  AppStep _step = AppStep.boot;
  late final WenxiangApi _api = widget.api ??
      WenxiangApi(
        baseUrl: AppEnv.publicUrl,
        apiKey: AppEnv.apiKey,
      );
  AppMemory? _memory;
  RepoItem? _repo;
  BookItem? _book;
  bool _bookExpandAsk = false;
  bool _bookOpening = false;
  RepoItem? _lastRepo;
  Object? _bootError;
  bool _booting = true;
  String _githubLogin = '';
  bool _githubConnected = false;
  bool _oauthAutoStart = false;
  final _reposKey = GlobalKey<ReposPageState>();

  bool _uploadingClientErrors = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _memory = widget.memory;
    _lastRepo = _memory?.lastRepo();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _boot();
      _uploadClientErrors();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshRoute());
      unawaited(_api.reportPresence('foreground'));
      _uploadClientErrors();
      if (NotificationCenter.instance.enabled.value) {
        unawaited(NotificationCenter.instance.fetchAndShowUnread());
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      unawaited(_api.reportPresence('background'));
      if (NotificationCenter.instance.enabled.value) {
        unawaited(BackgroundSync.acquire(_api));
      }
      _uploadClientErrors();
    }
  }

  Future<void> _uploadClientErrors() async {
    if (_uploadingClientErrors) return;
    _uploadingClientErrors = true;
    try {
      for (var round = 0; round < 5; round += 1) {
        final batch = await ClientErrorLog.instance.peek(40);
        if (batch.isEmpty) return;
        final accepted = await _api.uploadClientLogs(
          batch,
          platform: Platform.operatingSystem,
        );
        if (accepted.isEmpty) return;
        await ClientErrorLog.instance.drop(accepted);
        final sent = batch.map((entry) => entry['id']?.toString()).toSet();
        if (!sent.every(accepted.toSet().contains)) return;
      }
    } catch (_) {
      // Keep the local file. A failed upload must not record another error.
    } finally {
      _uploadingClientErrors = false;
    }
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
      final before = _api.baseUrl;
      await _api.preferLan(status.lanUrls);
      if (!mounted) return;
      if (_api.baseUrl != before && NotificationCenter.instance.enabled.value) {
        await NotificationCenter.instance.disconnect();
      }
      setState(() {
        _booting = false;
        _githubConnected = status.githubConnected;
        _githubLogin = status.githubLogin.isNotEmpty ? status.githubLogin : (memory?.githubLogin() ?? '');
        _oauthAutoStart = false;
        _lastRepo = memory?.lastRepo() ?? _lastRepo;
        _step = AppStep.repos;
      });
      if (status.githubLogin.isNotEmpty) {
        await memory?.saveGithubLogin(status.githubLogin);
      }
      if (NotificationCenter.instance.enabled.value) {
        // user opted in previously — restart the inbox socket now that api/key are known.
        unawaited(NotificationCenter.instance.setEnabled(_api, want: true));
      }
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _booting = false;
        _bootError = humanizeError(err);
        _step = AppStep.boot;
      });
    }
  }

  Future<void> _refreshRoute() async {
    final before = _api.baseUrl;
    try {
      await _api.preferLan(const []);
      final status = await _api.status();
      await _api.preferLan(status.lanUrls);
      if (_api.baseUrl != before && NotificationCenter.instance.enabled.value) {
        await NotificationCenter.instance.disconnect();
        unawaited(NotificationCenter.instance.connect());
      }
    } catch (_) {
      await _api.preferLan(const []);
    }
    if (mounted) setState(() {});
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

  void _openBooks() {
    setState(() => _step = AppStep.books);
  }

  void _openFiles() {
    setState(() => _step = AppStep.files);
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SettingsPage(api: _api, memory: _memory),
      ),
    );
  }

  void _backFromBooks() {
    setState(() => _step = AppStep.repos);
  }

  void _backFromFiles() {
    setState(() => _step = AppStep.repos);
  }

  Future<void> _openBookRead(BookItem book, {bool expandAsk = false}) async {
    if (_bookOpening) return;
    if (!mounted) return;
    setState(() => _bookOpening = true);
    try {
      if (!mounted) return;
      setState(() {
        _book = book;
        _bookExpandAsk = expandAsk;
        _step = AppStep.bookRead;
      });
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err.toString())),
      );
    } finally {
      if (mounted) setState(() => _bookOpening = false);
    }
  }

  void _backFromBookRead() {
    setState(() {
      _step = AppStep.books;
      _book = null;
      _bookExpandAsk = false;
    });
  }

  void _backFromChat() {
    setState(() {
      _step = AppStep.repos;
      _lastRepo = _memory?.lastRepo();
    });
  }

  bool _handlePop() {
    if (_step == AppStep.bookRead) {
      _backFromBookRead();
      return true;
    }
    if (_step == AppStep.books) {
      _backFromBooks();
      return true;
    }
    if (_step == AppStep.files) {
      _backFromFiles();
      return true;
    }
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
          onOpenBooks: _openBooks,
          onOpenFiles: _openFiles,
          onOpenSettings: _openSettings,
        )),
      ),
      if (_step == AppStep.files)
        WxFadePage<void>(
          key: const ValueKey('files'),
          name: 'files',
          child: _fit(StaticFilesPage(
            api: _api,
            onBack: _backFromFiles,
          )),
        ),
      if (_step == AppStep.books)
        WxFadePage<void>(
          key: const ValueKey('books'),
          name: 'books',
          child: _fit(BooksPage(
            api: _api,
            onBack: _backFromBooks,
            onRead: _openBookRead,
            opening: _bookOpening,
          )),
        ),
      if (_step == AppStep.bookRead && _book != null)
        WxFadePage<void>(
          key: ValueKey('book-read-${_book!.id}'),
          name: 'bookRead',
          child: _fit(BookReaderPage(
            api: _api,
            book: _book!,
            expandAsk: _bookExpandAsk,
            prefs: _memory?.prefs,
            memory: _memory,
            onBack: _backFromBookRead,
          )),
        ),
      if (_step == AppStep.chat && _repo != null)
        WxFadePage<void>(
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
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _handlePop();
      },
      child: WxEdgeBack(
        onBack: () {
          _handlePop();
        },
        child: SizedBox.expand(
          child: Navigator(
            pages: _pages(),
            onDidRemovePage: (page) {
              final name = page.name;
              if (name == 'bookRead' && _step == AppStep.bookRead) {
                _backFromBookRead();
              } else if (name == 'books' && _step == AppStep.books) {
                _backFromBooks();
              } else if (name == 'files' && _step == AppStep.files) {
                _backFromFiles();
              } else if (name == 'chat' && _step == AppStep.chat) {
                _backFromChat();
              }
            },
          ),
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
                  busy ? const WxLoading(size: 44) : const WxMark(size: 44),
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
                  if (error != null && !busy) ...[
                    const SizedBox(height: 28),
                    WxErrorPanel(error: error!, onRetry: onRetry),
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
