class ServerStatus {
  ServerStatus({
    required this.githubConnected,
    required this.githubLogin,
    required this.deviceFlowReady,
    required this.cursorAvailable,
    required this.cursorEngine,
    required this.tunnelUrl,
    required this.tunnelRunning,
    required this.tunnelError,
    required this.lanUrls,
  });

  final bool githubConnected;
  final String githubLogin;
  final bool deviceFlowReady;
  final bool cursorAvailable;
  final String cursorEngine;
  final String tunnelUrl;
  final bool tunnelRunning;
  final String tunnelError;
  final List<String> lanUrls;

  factory ServerStatus.fromJson(Map<String, dynamic> json) {
    final github = json['github'] as Map<String, dynamic>? ?? {};
    final user = github['user'] as Map<String, dynamic>?;
    final cursor = json['cursor'] as Map<String, dynamic>? ?? {};
    final tunnel = json['tunnel'] as Map<String, dynamic>? ?? {};
    return ServerStatus(
      githubConnected: github['connected'] == true,
      githubLogin: (user?['login'] ?? '').toString(),
      deviceFlowReady: github['deviceFlowReady'] == true,
      cursorAvailable: cursor['available'] == true,
      cursorEngine: (cursor['engine'] ?? cursor['fallback'] ?? 'local-progress')
          .toString(),
      tunnelUrl: (tunnel['publicUrl'] ?? '').toString(),
      tunnelRunning: tunnel['running'] == true,
      tunnelError: (tunnel['error'] ?? '').toString(),
      lanUrls: ((json['lanUrls'] as List?) ?? []).map((e) => e.toString()).toList(),
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
  ChatMessage({required this.role, required this.content, this.engine});

  final String role;
  final String content;
  final String? engine;
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
