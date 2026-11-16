import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wenxiang/models.dart';
import 'package:wenxiang/persist/app_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loading legacy history removes markers and duplicate final fragments', () async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    await memory.saveChats('octo/demo', RepoChatStore(
      sessions: [], activeId: 's1', transcripts: {'s1': [
        ChatMessage(role: 'user', content: '修改'),
        ChatMessage(role: 'assistant', content: '正在打包。===TASK_COMPLETED===已移除卡片。\n\n下载 APK。', engine: 'acp'),
        ChatMessage(role: 'assistant', content: '已'),
        ChatMessage(role: 'assistant', content: '正在打包。===TASK_COMPLETED===已移除卡片。\n\n下载 APK。'),
        ChatMessage(role: 'user', content: '下一轮'),
        ChatMessage(role: 'assistant', content: '已'),
      ]},
    ));
    final messages = memory.loadChats('octo/demo').transcripts['s1']!;
    expect(messages.map((m) => m.content), [
      '修改', '正在打包。\n\n已移除卡片。\n\n下载 APK。', '下一轮', '已',
    ]);
    expect(messages[1].engine, 'acp');
  });

  test('remembers last repo and chat turns without storing secrets', () async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final repo = RepoItem(
      owner: 'octo',
      name: 'demo',
      fullName: 'octo/demo',
      description: '示例',
      privateRepo: false,
      language: 'Dart',
      pushedAt: '2026-09-16T00:00:00Z',
    );
    await memory.saveLastRepo(repo);
    await memory.saveGithubLogin('octo');
    await memory.saveChats(
      repo.fullName,
      RepoChatStore(
        activeId: 's1',
        sessions: [
          ChatSession(
            id: 's1',
            title: '这个仓库最近在做什么？',
            createdAt: '2026-09-16T00:00:00Z',
            updatedAt: '2026-09-16T00:00:00Z',
            active: true,
          ),
        ],
        transcripts: {
          's1': [
            ChatMessage(role: 'user', content: '这个仓库最近在做什么？'),
            ChatMessage(role: 'assistant', content: '最近在修登录。', engine: 'local-progress'),
          ],
        },
      ),
    );

    expect(memory.lastRepo()?.fullName, 'octo/demo');
    expect(memory.githubLogin(), 'octo');
    final chats = memory.loadChats('octo/demo');
    expect(chats.activeId, 's1');
    expect(chats.transcripts['s1']?.last.content, '最近在修登录。');

    final raw = memory.prefs.getKeys().map((key) => memory.prefs.get(key).toString()).join(' ');
    expect(raw.toLowerCase(), isNot(contains('token')));
    expect(raw.toLowerCase(), isNot(contains('secret')));
    expect(raw.toLowerCase(), isNot(contains('bearer')));
    expect(raw, isNot(contains('x-access-token')));
  });

  test('persists TTS voice and defaults to 小何 2.0', () async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    expect(memory.ttsVoice(), 'zh_female_xiaohe_uranus_bigtts');
    await memory.saveTtsVoice('zh_male_m191_uranus_bigtts');
    expect(memory.ttsVoice(), 'zh_male_m191_uranus_bigtts');
    await memory.saveTtsVoice(' not a voice ');
    expect(memory.ttsVoice(), 'zh_female_xiaohe_uranus_bigtts');
  });

  test('agent mode is stored per repo and defaults off', () async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    expect(memory.agentModeFor('octo/demo'), isFalse);
    expect(memory.agentModeFor('octo/widget'), isFalse);
    await memory.saveAgentMode('octo/demo', true);
    expect(memory.agentModeFor('octo/demo'), isTrue);
    expect(memory.agentModeFor('octo/widget'), isFalse);
    await memory.saveAgentMode('octo/demo', false);
    expect(memory.agentModeFor('octo/demo'), isFalse);
  });

  test('keeps last-used repo at the front of recent repos', () async {
    SharedPreferences.setMockInitialValues({});
    final memory = AppMemory(await SharedPreferences.getInstance());
    final first = sampleLike('octo/demo');
    final second = sampleLike('octo/widget');
    await memory.rememberRepos([second, first]);
    await memory.saveLastRepo(first);
    expect(memory.recentRepos().map((repo) => repo.fullName).toList(), ['octo/demo', 'octo/widget']);
    expect(memory.lastRepo()?.fullName, 'octo/demo');
  });
}

RepoItem sampleLike(String fullName) {
  final parts = fullName.split('/');
  return RepoItem(
    owner: parts[0],
    name: parts[1],
    fullName: fullName,
    description: '',
    privateRepo: false,
    language: 'Dart',
    pushedAt: '2026-09-16T00:00:00Z',
  );
}
