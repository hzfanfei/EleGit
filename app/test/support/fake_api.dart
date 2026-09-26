import 'dart:typed_data';

import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/copy/ask_engine.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/models/diagnostics.dart';
import 'package:wenxiang/voice/cosyvoice_tts_voices.dart';
import 'package:wenxiang/voice/tts_voice_catalog.dart';
import 'package:wenxiang/voice/volc_tts_voices.dart';
import 'package:wenxiang/voice/xiaomi_tts_voices.dart';

class FakeWenxiangApi extends WenxiangApi {
  FakeWenxiangApi({
    this.oauthThrows,
    this.oauthCompletes = false,
    this.githubConnected = true,
    this.githubLogin = 'octo',
    this.reposResult,
    this.reposThrows,
    this.localReposResult,
    this.localReposThrows,
    this.checkoutPath = '/home/fei/问象/octo/demo',
    this.checkoutDelay = Duration.zero,
    this.checkoutThrows,
    this.checkoutStatusResult,
    this.checkoutStatusThrows,
    this.streamEvents,
    this.streamThrows,
    this.streamDelay = Duration.zero,
    this.streamPace = Duration.zero,
    this.voiceReady = false,
    this.voiceHint = '还没配语音密钥。请在本机问象服务的 .env 里配置。',
    this.voiceTtsProvider = 'volc',
    this.bookVoiceTurnEvents,
    this.repoVoiceTurnEvents,
    this.booksResult = const [],
  }) : super(baseUrl: 'http://127.0.0.1:8787', apiKey: 'test-key');

  Object? oauthThrows;
  bool oauthCompletes;
  bool githubConnected;
  String githubLogin;
  List<RepoItem>? reposResult;
  Object? reposThrows;
  List<RepoItem>? localReposResult;
  Object? localReposThrows;
  String checkoutPath;
  Duration checkoutDelay;
  Object? checkoutThrows;
  CheckoutSyncStatus? checkoutStatusResult;
  Object? checkoutStatusThrows;
  List<ChatStreamEvent>? streamEvents;
  Object? streamThrows;
  Duration streamDelay;
  Duration streamPace;
  bool voiceReady;
  String voiceHint;
  String voiceTtsProvider;
  int startOAuthCalls = 0;
  int checkoutCalls = 0;
  int checkoutStatusCalls = 0;
  int cancelCheckoutCalls = 0;
  int cancelChatCalls = 0;
  int cancelBookVoiceTurnCalls = 0;
  int cancelRepoVoiceTurnCalls = 0;
  List<ChatStreamEvent>? bookVoiceTurnEvents;
  List<ChatStreamEvent>? repoVoiceTurnEvents;
  String? lastSessionId;
  String? lastChatMessage;
  final List<String> chatMessages = <String>[];
  final List<List<ChatMessage>> chatHistories = <List<ChatMessage>>[];
  String? lastBookTtsVoice;
  String? lastRepoTtsVoice;
  String? lastSetTtsVoice;
  String? lastSetAskEngine;
  String? lastSetAskEngineScope;
  String? lastSetVoiceStack;
  int createSessionCalls = 0;
  final List<ChatSession> sessions = [
    ChatSession(
      id: 's1',
      title: '新会话',
      createdAt: '2026-09-15T00:00:00.000Z',
      updatedAt: '2026-09-15T00:00:00.000Z',
      active: true,
    ),
  ];

  @override
  Future<void> ping() async {}

  @override
  Future<void> preferLan(List<String> lanUrls) async {}

  final List<List<Map<String, dynamic>>> uploadedClientLogs = [];

  @override
  Future<List<String>> uploadClientLogs(
    List<Map<String, dynamic>> entries, {
    String app = 'wenxiang',
    String platform = '',
  }) async {
    uploadedClientLogs.add([
      for (final entry in entries) Map<String, dynamic>.from(entry),
    ]);
    return [
      for (final entry in entries)
        if (entry['id'] != null) entry['id'].toString(),
    ];
  }

  @override
  Future<void> setVoiceStack(String stack) async {
    lastSetVoiceStack = stack;
    if (stack == 'local') {
      voiceTtsProvider = 'cosyvoice';
    } else if (stack == 'xiaomi') {
      voiceTtsProvider = 'xiaomi';
    } else {
      voiceTtsProvider = 'volc';
    }
  }

  @override
  Future<void> setAskEngine(String engine, {required AskEngineScope scope}) async {
    lastSetAskEngine = engine;
    lastSetAskEngineScope = askEngineScopeId(scope);
  }

  @override
  Future<void> setTtsVoice(String ttsVoice) async {
    lastSetTtsVoice = ttsVoice;
  }

  String? lastPreviewTtsVoice;

  @override
  Future<TtsVoicePreview> previewTtsVoice(String ttsVoice, {String? text}) async {
    lastPreviewTtsVoice = ttsVoice;
    if (!voiceReady) {
      throw ApiException('语音未就绪');
    }
    return TtsVoicePreview(pcm: Uint8List(480), sampleRate: 24000);
  }

  @override
  Future<DiagnosticsProbeResult> runDiagnosticsProbe({String? ttsVoice}) async {
    return DiagnosticsProbeResult(
      ok: true,
      at: DateTime.now().toUtc().toIso8601String(),
      askCliBook: DiagnosticsStep(ok: true, ms: 40),
      askCliRepo: DiagnosticsStep(ok: true, ms: 42),
      askModelBook: DiagnosticsStep(ok: true, ms: 880, snippet: '通'),
      askModelRepo: DiagnosticsStep(ok: true, ms: 900, snippet: '通'),
      voiceTts: DiagnosticsVoiceTtsStep(ok: voiceReady, ms: 120, bytes: voiceReady ? 480 : 0),
      voiceStt: DiagnosticsVoiceSttStep(ok: voiceReady, ms: 80),
    );
  }

  List<BookItem> booksResult;

  @override
  Future<List<BookItem>> listBooks() async => booksResult;

  @override
  Future<List<ChatSession>> listBookSessions(String bookId) async => List<ChatSession>.from(sessions);

  @override
  Future<ChatSession> createBookSession(String bookId) async => createSession('_book', bookId);

  @override
  Future<void> closeBookSession(String bookId, String id) async => closeSession('_book', bookId, id);

  @override
  Future<void> warmBookSession(String bookId, {String? sessionId}) async {}

  @override
  Future<BookReadingManifest> fetchBookReadingManifest(String bookId) async {
    const chapters = [
      BookChapterEntry(index: 0, file: '001-chapter.md', title: '第一章'),
    ];
    return BookReadingManifest(
      bookId: bookId,
      title: 'Test book',
      author: '',
      converter: 'plain',
      chapters: chapters,
      toc: [BookTocEntry(index: 0, title: '第一章')],
    );
  }

  @override
  Future<String> fetchBookChapterMarkdown(String bookId, String filename) async {
    return '# 第一章\n\n正文。';
  }

  @override
  Stream<ChatStreamEvent> bookChatStream({
    required String bookId,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? chapter,
  }) =>
      chatStream(
        owner: '_book',
        repo: bookId,
        message: message,
        history: history,
        sessionId: sessionId,
      );

  @override
  Future<void> warmChatSession(
    String owner,
    String repo, {
    String? sessionId,
  }) async {}

  VoiceServiceProfile _voiceProfileForFake() {
    if (voiceTtsProvider == 'xiaomi') {
      return VoiceServiceProfile(
        ready: voiceReady,
        hint: voiceReady ? '' : voiceHint,
        voiceStack: 'xiaomi',
        ttsProvider: 'xiaomi',
        ttsEngine: 'mimo-v2.5-tts',
        asrProvider: 'xiaomi',
        asrEngine: 'mimo-v2.5-asr',
        ttsVoice: kDefaultXiaomiTtsVoice,
        voices: kXiaomiTtsVoices
            .map((v) => TtsVoiceOption(id: v.id, name: v.name, scene: v.scene))
            .toList(),
      );
    }
    if (voiceTtsProvider == 'cosyvoice') {
      return VoiceServiceProfile(
        ready: voiceReady,
        hint: voiceReady ? '' : voiceHint,
        ttsProvider: 'cosyvoice',
        ttsEngine: 'Fun-CosyVoice3',
        asrProvider: 'funasr',
        asrEngine: 'FunASR-Paraformer',
        ttsVoice: kDefaultCosyvoiceTtsVoice,
        voices: kCosyvoiceTtsVoices
            .map(
              (v) => TtsVoiceOption(id: v.id, name: v.name, scene: v.scene),
            )
            .toList(),
      );
    }
    return VoiceServiceProfile(
      ready: voiceReady,
      hint: voiceReady ? '' : voiceHint,
      ttsProvider: 'volc',
      ttsEngine: 'volc',
      asrProvider: 'volc',
      asrEngine: 'volc',
      ttsVoice: kDefaultVolcTtsVoice,
      voices: kVolcTtsVoices
          .map((v) => TtsVoiceOption(id: v.id, name: v.name, scene: v.scene))
          .toList(),
    );
  }

  @override
  Future<ServerStatus> status() async {
    return ServerStatus(
      githubConnected: githubConnected,
      githubLogin: githubLogin,
      oauthReady: true,
      callbackUrls: const [],
      deviceFlowReady: false,
      cursorAvailable: false,
      cursorEngine: 'local-progress',
      askEnginePreference: 'claude',
      askEngineBookPreference: 'claude',
      askEngineRepoPreference: 'claude',
      tunnelUrl: '',
      tunnelRunning: false,
      tunnelError: '',
      lanUrls: const [],
      workspaceRoot: '/home/fei/问象',
      voiceReady: voiceReady,
      voiceHint: voiceReady ? '' : voiceHint,
      voiceProfile: _voiceProfileForFake(),
    );
  }

  @override
  Future<OAuthStart> startOAuth() async {
    startOAuthCalls += 1;
    if (oauthThrows != null) throw oauthThrows!;
    return OAuthStart(
      state: 'st',
      authorizeUrl: 'https://github.com/login/oauth/authorize?state=st',
      redirectUri: 'http://127.0.0.1:8787/oauth/github/callback',
    );
  }

  @override
  Future<bool> pollOAuth(String state) async => oauthCompletes;

  @override
  Future<List<RepoItem>> repos(String query) async {
    if (reposThrows != null) throw reposThrows!;
    final all = reposResult ??
        [
          RepoItem(
            owner: 'octo',
            name: 'demo',
            fullName: 'octo/demo',
            description: '示例仓库',
            privateRepo: true,
            language: 'Dart',
            pushedAt: '2026-09-15T00:00:00Z',
          ),
        ];
    if (query.isEmpty) return all;
    return all.where((r) => r.fullName.contains(query)).toList();
  }

  @override
  Future<List<RepoItem>> localRepos(String query) async {
    if (localReposThrows != null) throw localReposThrows!;
    final all = localReposResult ??
        reposResult ??
        [
          RepoItem(
            owner: 'octo',
            name: 'demo',
            fullName: 'octo/demo',
            description: '本机仓库',
            privateRepo: false,
            language: 'Dart',
            pushedAt: '2026-09-15T00:00:00Z',
          ),
        ];
    if (query.isEmpty) return all;
    return all.where((r) => r.fullName.contains(query)).toList();
  }

  @override
  Future<CheckoutSyncStatus> checkoutStatus(String owner, String repo) async {
    checkoutStatusCalls += 1;
    if (checkoutStatusThrows != null) throw checkoutStatusThrows!;
    return checkoutStatusResult ??
        CheckoutSyncStatus(
          present: true,
          upToDate: true,
          syncState: 'current',
          behind: 0,
          path: checkoutPath,
        );
  }

  @override
  Future<CheckoutResult> checkout(String owner, String repo) async {
    checkoutCalls += 1;
    if (checkoutDelay > Duration.zero) {
      await Future<void>.delayed(checkoutDelay);
    }
    if (checkoutThrows != null) throw checkoutThrows!;
    return CheckoutResult(path: checkoutPath, branch: 'main', head: 'abc');
  }

  @override
  void cancelCheckout() {
    cancelCheckoutCalls += 1;
    checkoutThrows ??= const OperationCancelled();
  }

  @override
  void cancelChat({String? sessionId}) {
    cancelChatCalls += 1;
    streamThrows ??= const OperationCancelled();
  }

  @override
  void cancelBookVoiceTurn() {
    cancelBookVoiceTurnCalls += 1;
  }

  @override
  void cancelRepoVoiceTurn() {
    cancelRepoVoiceTurnCalls += 1;
  }

  @override
  Stream<ChatStreamEvent> bookVoiceTurnStream({
    required String bookId,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? chapter,
    String? ttsVoice,
  }) async* {
    lastBookTtsVoice = ttsVoice;
    for (final event in bookVoiceTurnEvents ??
        [
          ChatStreamEvent(type: 'caption', text: '演示回答。'),
          ChatStreamEvent(type: 'done', text: '演示回答。', engine: 'acp'),
        ]) {
      yield event;
    }
  }

  @override
  Stream<ChatStreamEvent> repoVoiceTurnStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    String? ttsVoice,
    bool agentMode = false,
  }) async* {
    lastRepoTtsVoice = ttsVoice;
    for (final event in repoVoiceTurnEvents ??
        [
          ChatStreamEvent(type: 'caption', text: '仓库回答。'),
          ChatStreamEvent(type: 'done', text: '仓库回答。', engine: 'acp'),
        ]) {
      yield event;
    }
  }

  @override
  Future<List<ChatSession>> listSessions(String owner, String repo) async {
    return List<ChatSession>.from(sessions);
  }

  @override
  Future<ChatSession> createSession(String owner, String repo) async {
    createSessionCalls += 1;
    final created = ChatSession(
      id: 's${sessions.length + 1}',
      title: '新会话',
      createdAt: '2026-09-15T00:00:00.000Z',
      updatedAt: '2026-09-15T00:00:00.000Z',
      active: true,
    );
    sessions.insert(0, created);
    return created;
  }

  @override
  Future<void> closeSession(String owner, String repo, String id) async {
    sessions.removeWhere((s) => s.id == id);
  }

  @override
  Stream<ChatStreamEvent> chatStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
    String? sessionId,
    bool agentMode = false,
  }) async* {
    lastSessionId = sessionId;
    lastChatMessage = message;
    chatMessages.add(message);
    chatHistories.add(List<ChatMessage>.from(history));
    if (streamThrows != null) throw streamThrows!;
    if (streamDelay > Duration.zero) {
      await Future<void>.delayed(streamDelay);
    }
    if (streamThrows != null) throw streamThrows!;
    final events = streamEvents ??
        [
          ChatStreamEvent(type: 'start', engine: 'local-progress'),
          ChatStreamEvent(
            type: 'delta',
            text: message.contains('README') ? 'README 说先跑 flutter run。' : '最近在修登录。',
          ),
          ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: sessionId ?? 's1'),
        ];
    for (final event in events) {
      if (streamPace > Duration.zero) {
        await Future<void>.delayed(streamPace);
      }
      yield event;
      if (event.type == 'done') {
        final id = event.sessionId ?? sessionId ?? (sessions.isEmpty ? null : sessions.first.id);
        if (id == null) continue;
        final index = sessions.indexWhere((s) => s.id == id);
        if (index < 0) continue;
        final prior = sessions[index];
        if (prior.title != '新会话') continue;
        final title = message.replaceAll(RegExp(r'\s+'), ' ');
        sessions[index] = ChatSession(
          id: prior.id,
          title: title.length <= 32 ? title : title.substring(0, 32),
          createdAt: prior.createdAt,
          updatedAt: prior.updatedAt,
          active: prior.active,
        );
      }
    }
  }
}

RepoItem sampleRepo() {
  return RepoItem(
    owner: 'octo',
    name: 'demo',
    fullName: 'octo/demo',
    description: '示例仓库',
    privateRepo: false,
    language: 'Dart',
    pushedAt: '2026-09-15T00:00:00Z',
  );
}
