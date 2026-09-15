import 'dart:convert';

class ServerStatus {
  ServerStatus({
    required this.githubConnected,
    required this.githubLogin,
    required this.oauthReady,
    required this.callbackUrls,
    required this.deviceFlowReady,
    required this.cursorAvailable,
    required this.cursorEngine,
    required this.tunnelUrl,
    required this.tunnelRunning,
    required this.tunnelError,
    required this.lanUrls,
    required this.workspaceRoot,
  });

  final bool githubConnected;
  final String githubLogin;
  final bool oauthReady;
  final List<String> callbackUrls;
  final bool deviceFlowReady;
  final bool cursorAvailable;
  final String cursorEngine;
  final String tunnelUrl;
  final bool tunnelRunning;
  final String tunnelError;
  final List<String> lanUrls;
  final String workspaceRoot;

  factory ServerStatus.fromJson(Map<String, dynamic> json) {
    final github = json['github'] as Map<String, dynamic>? ?? {};
    final user = github['user'] as Map<String, dynamic>?;
    final cursor = json['cursor'] as Map<String, dynamic>? ?? {};
    final tunnel = json['tunnel'] as Map<String, dynamic>? ?? {};
    final workspace = json['workspace'] as Map<String, dynamic>? ?? {};
    return ServerStatus(
      githubConnected: github['connected'] == true,
      githubLogin: (user?['login'] ?? '').toString(),
      oauthReady: github['oauthReady'] == true,
      callbackUrls:
          ((github['callbackUrls'] as List?) ?? []).map((e) => e.toString()).toList(),
      deviceFlowReady: github['deviceFlowReady'] == true,
      cursorAvailable: cursor['available'] == true,
      cursorEngine: (cursor['engine'] ?? cursor['fallback'] ?? 'local-progress')
          .toString(),
      tunnelUrl: (tunnel['publicUrl'] ?? '').toString(),
      tunnelRunning: tunnel['running'] == true,
      tunnelError: (tunnel['error'] ?? '').toString(),
      lanUrls: ((json['lanUrls'] as List?) ?? []).map((e) => e.toString()).toList(),
      workspaceRoot: (workspace['root'] ?? '').toString(),
    );
  }
}

class RepoItem {
  RepoItem({
    required this.owner,
    required this.name,
    required this.fullName,
    required this.description,
    required this.privateRepo,
    required this.language,
    required this.pushedAt,
  });

  final String owner;
  final String name;
  final String fullName;
  final String description;
  final bool privateRepo;
  final String language;
  final String pushedAt;

  factory RepoItem.fromJson(Map<String, dynamic> json) {
    return RepoItem(
      owner: (json['owner'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      fullName: (json['fullName'] ?? '').toString(),
      description: (json['description'] ?? '').toString(),
      privateRepo: json['private'] == true,
      language: (json['language'] ?? '').toString(),
      pushedAt: (json['pushedAt'] ?? '').toString(),
    );
  }
}

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    this.engine,
    this.streaming = false,
  });

  final String role;
  String content;
  String? engine;
  bool streaming;
}

class ChatStreamEvent {
  ChatStreamEvent({required this.type, this.text = '', this.engine, this.error});

  final String type;
  final String text;
  final String? engine;
  final String? error;

  static ChatStreamEvent? fromSse(String raw) {
    final lines = raw.split('\n');
    final data = lines
        .where((line) => line.startsWith('data:'))
        .map((line) => line.substring(5).trim())
        .join();
    if (data.isEmpty) return null;
    try {
      final json = jsonDecode(data);
      if (json is! Map) return null;
      return ChatStreamEvent(
        type: (json['type'] ?? '').toString(),
        text: (json['text'] ?? json['answer'] ?? '').toString(),
        engine: json['engine']?.toString(),
        error: json['error']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

class DeviceStart {
  DeviceStart({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int interval;
}

class OAuthStart {
  OAuthStart({
    required this.state,
    required this.authorizeUrl,
    required this.redirectUri,
  });

  final String state;
  final String authorizeUrl;
  final String redirectUri;
}

class CheckoutResult {
  CheckoutResult({required this.path, required this.branch, required this.head});

  final String path;
  final String branch;
  final String head;
}
