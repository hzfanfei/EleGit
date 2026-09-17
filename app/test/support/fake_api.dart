import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';

class FakeWenxiangApi extends WenxiangApi {
  FakeWenxiangApi({
    this.oauthThrows,
    this.oauthCompletes = false,
    this.githubConnected = true,
    this.githubLogin = 'octo',
    this.reposResult,
    this.reposThrows,
    this.checkoutPath = '/home/fei/问象/octo/demo',
    this.checkoutDelay = Duration.zero,
    this.checkoutThrows,
    this.streamEvents,
    this.streamThrows,
    this.streamDelay = Duration.zero,
    this.streamPace = Duration.zero,
    this.voiceReady = false,
    this.voiceHint = '还没配语音密钥',
  }) : super(baseUrl: 'http://127.0.0.1:8787', apiKey: 'test-key');

  Object? oauthThrows;
  bool oauthCompletes;
  bool githubConnected;
  String githubLogin;
  List<RepoItem>? reposResult;
  Object? reposThrows;
  String checkoutPath;
  Duration checkoutDelay;
  Object? checkoutThrows;
  List<ChatStreamEvent>? streamEvents;
  Object? streamThrows;
  Duration streamDelay;
  Duration streamPace;
  bool voiceReady;
  String voiceHint;
  int startOAuthCalls = 0;
  int checkoutCalls = 0;
  int cancelCheckoutCalls = 0;
  int cancelChatCalls = 0;
  String? lastSessionId;
  String? lastChatMessage;
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
  Future<ServerStatus> status() async {
    return ServerStatus(
      githubConnected: githubConnected,
      githubLogin: githubLogin,
      oauthReady: true,
      callbackUrls: const [],
      deviceFlowReady: false,
      cursorAvailable: false,
      cursorEngine: 'local-progress',
      tunnelUrl: '',
      tunnelRunning: false,
      tunnelError: '',
      lanUrls: const [],
      workspaceRoot: '/home/fei/问象',
      voiceReady: voiceReady,
      voiceHint: voiceReady ? '' : voiceHint,
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
  void cancelChat() {
    cancelChatCalls += 1;
    streamThrows ??= const OperationCancelled();
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
  }) async* {
    lastSessionId = sessionId;
    lastChatMessage = message;
    if (streamThrows != null) throw streamThrows!;
    if (streamDelay > Duration.zero) {
      await Future<void>.delayed(streamDelay);
    }
    if (streamThrows != null) throw streamThrows!;
    for (final event in streamEvents ??
        [
          ChatStreamEvent(type: 'start', engine: 'local-progress'),
          ChatStreamEvent(
            type: 'delta',
            text: message.contains('README') ? 'README 说先跑 flutter run。' : '最近在修登录。',
          ),
          ChatStreamEvent(type: 'done', engine: 'local-progress', sessionId: sessionId ?? 's1'),
        ]) {
      if (streamPace > Duration.zero) {
        await Future<void>.delayed(streamPace);
      }
      yield event;
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
