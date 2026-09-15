import 'package:wenxiang/api/wenxiang_api.dart';
import 'package:wenxiang/models.dart';

class FakeWenxiangApi extends WenxiangApi {
  FakeWenxiangApi({
    this.oauthThrows,
    this.oauthCompletes = false,
    this.reposResult,
    this.reposThrows,
    this.checkoutPath = '/home/fei/问象/octo/demo',
    this.checkoutThrows,
    this.streamEvents,
    this.streamThrows,
  }) : super(baseUrl: 'http://127.0.0.1:8787', apiKey: 'test-key');

  Object? oauthThrows;
  bool oauthCompletes;
  List<RepoItem>? reposResult;
  Object? reposThrows;
  String checkoutPath;
  Object? checkoutThrows;
  List<ChatStreamEvent>? streamEvents;
  Object? streamThrows;
  int startOAuthCalls = 0;
  int checkoutCalls = 0;

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
    if (checkoutThrows != null) throw checkoutThrows!;
    return CheckoutResult(path: checkoutPath, branch: 'main', head: 'abc');
  }

  @override
  Stream<ChatStreamEvent> chatStream({
    required String owner,
    required String repo,
    required String message,
    required List<ChatMessage> history,
  }) async* {
    if (streamThrows != null) throw streamThrows!;
    for (final event in streamEvents ??
        [
          ChatStreamEvent(type: 'start', engine: 'local-progress'),
          ChatStreamEvent(type: 'delta', text: '最近在修登录。'),
          ChatStreamEvent(type: 'done', engine: 'local-progress'),
        ]) {
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
