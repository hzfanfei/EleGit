import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../copy/ask_engine.dart';
import '../models.dart';
import '../voice/volc_tts_voices.dart';
import 'book_chat_store.dart';

/// Local-only place memory. Never stores tokens, API keys, or OAuth secrets.
class AppMemory {
  AppMemory(this.prefs);

  final SharedPreferences prefs;

  static const lastRepoKey = 'wx.lastRepo';
  static const githubLoginKey = 'wx.githubLogin';
  static const recentReposKey = 'wx.recentRepos';
  static const voiceHoldTipDismissedKey = 'wx.voiceHoldTipDismissed';
  static const chatVoiceInputKey = 'wx.chatVoiceInput';
  static const ttsVoiceKey = 'wx.ttsVoice';
  static const askEngineKey = 'wx.askEngine';
  static const askEngineBookKey = 'wx.askEngine.book';
  static const askEngineRepoKey = 'wx.askEngine.repo';

  static String chatsKey(String fullName) => 'wx.chats.$fullName';
  static String bookChatsKey(String bookId) => 'wx.bookChats.$bookId';
  static String agentModeKey(String fullName) => 'wx.agentMode.$fullName';

  bool agentModeFor(String fullName) => prefs.getBool(agentModeKey(fullName)) ?? false;

  Future<void> saveAgentMode(String fullName, bool enabled) {
    if (!enabled) return prefs.remove(agentModeKey(fullName));
    return prefs.setBool(agentModeKey(fullName), true);
  }

  bool voiceHoldTipDismissed() => prefs.getBool(voiceHoldTipDismissedKey) ?? false;

  bool chatVoiceInput() => prefs.getBool(chatVoiceInputKey) ?? false;

  Future<void> saveChatVoiceInput(bool voice) => prefs.setBool(chatVoiceInputKey, voice);

  Future<void> dismissVoiceHoldTip() => prefs.setBool(voiceHoldTipDismissedKey, true);

  String ttsVoice() => resolveVolcTtsVoice(prefs.getString(ttsVoiceKey)).id;

  AskEngineChoice _readAskEngine(String? primary, String? fallback) {
    return parseAskEngineChoice(primary ?? fallback);
  }

  bool hasLegacyAskEngineKey() => prefs.containsKey(askEngineKey);

  bool hasAskEngineBookKey() => prefs.containsKey(askEngineBookKey);

  bool hasAskEngineRepoKey() => prefs.containsKey(askEngineRepoKey);

  /// True when the user (or legacy single switch) picked 问书 engine on this device.
  bool askEngineBookIsExplicit() => hasAskEngineBookKey() || hasLegacyAskEngineKey();

  /// True when the user (or legacy single switch) picked 问象 engine on this device.
  bool askEngineRepoIsExplicit() => hasAskEngineRepoKey() || hasLegacyAskEngineKey();

  AskEngineChoice askEngineBook() =>
      _readAskEngine(prefs.getString(askEngineBookKey), prefs.getString(askEngineKey));

  AskEngineChoice askEngineRepo() =>
      _readAskEngine(prefs.getString(askEngineRepoKey), prefs.getString(askEngineKey));

  /// Legacy alias for repo scope.
  AskEngineChoice askEngine() => askEngineRepo();

  Future<void> saveAskEngineFor(AskEngineScope scope, AskEngineChoice choice) {
    final id = askEngineChoiceId(choice);
    switch (scope) {
      case AskEngineScope.book:
        return prefs.setString(askEngineBookKey, id);
      case AskEngineScope.repo:
        return prefs.setString(askEngineRepoKey, id);
    }
  }

  Future<void> saveAskEngine(AskEngineChoice choice) {
    return saveAskEngineFor(AskEngineScope.repo, choice);
  }

  Future<void> saveTtsVoice(String voice) {
    final id = sanitizeVolcTtsVoice(voice);
    return prefs.setString(ttsVoiceKey, id.isEmpty ? kDefaultVolcTtsVoice : id);
  }

  RepoItem? lastRepo() {
    final raw = prefs.getString(lastRepoKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return RepoItem.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveLastRepo(RepoItem repo) async {
    await prefs.setString(lastRepoKey, jsonEncode(repo.toJson()));
    await rememberOpened(repo);
  }

  List<RepoItem> recentRepos() {
    final raw = prefs.getString(recentReposKey);
    if (raw == null || raw.isEmpty) {
      final last = lastRepo();
      return last == null ? const [] : [last];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map>()
          .map((item) => RepoItem.fromJson(Map<String, dynamic>.from(item)))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> rememberOpened(RepoItem repo) {
    final next = [
      repo,
      ...recentRepos().where((item) => item.fullName != repo.fullName),
    ];
    return prefs.setString(
      recentReposKey,
      jsonEncode(next.take(8).map((item) => item.toJson()).toList()),
    );
  }

  Future<void> rememberRepos(List<RepoItem> repos) {
    final last = lastRepo();
    final seen = <String>{};
    final next = <RepoItem>[];
    void add(RepoItem? repo) {
      if (repo == null || repo.fullName.isEmpty || seen.contains(repo.fullName)) {
        return;
      }
      seen.add(repo.fullName);
      next.add(repo);
    }

    add(last);
    for (final repo in recentRepos()) {
      add(repo);
    }
    for (final repo in repos) {
      add(repo);
    }
    return prefs.setString(
      recentReposKey,
      jsonEncode(next.take(8).map((item) => item.toJson()).toList()),
    );
  }

  String githubLogin() => prefs.getString(githubLoginKey) ?? '';

  Future<void> saveGithubLogin(String login) {
    if (login.isEmpty) return prefs.remove(githubLoginKey);
    return prefs.setString(githubLoginKey, login);
  }

  RepoChatStore loadChats(String fullName) {
    final raw = prefs.getString(chatsKey(fullName));
    if (raw == null || raw.isEmpty) return RepoChatStore.empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return RepoChatStore.empty();
      return RepoChatStore.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return RepoChatStore.empty();
    }
  }

  Future<void> saveChats(String fullName, RepoChatStore store) {
    return prefs.setString(chatsKey(fullName), jsonEncode(store.toJson()));
  }

  BookChatStore loadBookChats(String bookId) {
    final raw = prefs.getString(bookChatsKey(bookId));
    if (raw == null || raw.isEmpty) return BookChatStore.empty();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return BookChatStore.empty();
      return BookChatStore.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return BookChatStore.empty();
    }
  }

  Future<void> saveBookChats(String bookId, BookChatStore store) {
    return prefs.setString(bookChatsKey(bookId), jsonEncode(store.toJson()));
  }
}

class RepoChatStore {
  RepoChatStore({
    required this.sessions,
    required this.activeId,
    required this.transcripts,
  });

  final List<ChatSession> sessions;
  final String? activeId;
  final Map<String, List<ChatMessage>> transcripts;

  factory RepoChatStore.empty() => RepoChatStore(
        sessions: const [],
        activeId: null,
        transcripts: const {},
      );

  factory RepoChatStore.fromJson(Map<String, dynamic> json) {
    final sessions = ((json['sessions'] as List?) ?? [])
        .whereType<Map>()
        .map((item) => ChatSession.fromJson(Map<String, dynamic>.from(item)))
        .toList();
    final transcripts = <String, List<ChatMessage>>{};
    final raw = json['transcripts'];
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is! List) return;
        transcripts[key.toString()] = value
            .whereType<Map>()
            .map((item) => ChatMessage.fromJson(Map<String, dynamic>.from(item)))
            .toList();
      });
    }
    return RepoChatStore(
      sessions: sessions,
      activeId: json['activeId']?.toString(),
      transcripts: transcripts,
    );
  }

  Map<String, dynamic> toJson() => {
        'activeId': activeId,
        'sessions': sessions.map((session) => session.toJson()).toList(),
        'transcripts': transcripts.map(
          (key, value) => MapEntry(key, value.map((item) => item.toJson()).toList()),
        ),
      };
}
