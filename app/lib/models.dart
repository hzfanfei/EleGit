import 'dart:convert';
import 'dart:typed_data';

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
    this.voiceReady = false,
    this.voiceHint = '还没配语音密钥。请在本机问象服务的 .env 里配置。',
    this.publicReachable,
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
  final bool voiceReady;
  final String voiceHint;
  final bool? publicReachable;

  factory ServerStatus.fromJson(Map<String, dynamic> json) {
    final github = json['github'] as Map<String, dynamic>? ?? {};
    final user = github['user'] as Map<String, dynamic>?;
    final cursor = json['cursor'] as Map<String, dynamic>? ?? {};
    final tunnel = json['tunnel'] as Map<String, dynamic>? ?? {};
    final workspace = json['workspace'] as Map<String, dynamic>? ?? {};
    final voice = json['voice'] as Map<String, dynamic>? ?? {};
    final tunnelHealth = json['tunnelHealth'] as Map<String, dynamic>? ?? {};
    final reachable = tunnelHealth['reachable'] ?? tunnel['publicReachable'];
    return ServerStatus(
      githubConnected: github['connected'] == true ||
          github['connected'] == 'true' ||
          (user?['login'] ?? '').toString().trim().isNotEmpty,
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
      voiceReady: voice['ready'] == true,
      voiceHint: voice['ready'] == true
          ? ''
          : (voice['hint'] ?? '还没配语音密钥。请在本机问象服务的 .env 里配置。').toString(),
      publicReachable: reachable == true ? true : reachable == false ? false : null,
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

  Map<String, dynamic> toJson() => {
        'owner': owner,
        'name': name,
        'fullName': fullName,
        'description': description,
        'private': privateRepo,
        'language': language,
        'pushedAt': pushedAt,
      };
}

class ChatSession {
  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.active,
  });

  final String id;
  final String title;
  final String createdAt;
  final String updatedAt;
  final bool active;

  factory ChatSession.fromJson(Map<String, dynamic> json) {
    return ChatSession(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '新会话').toString(),
      createdAt: (json['createdAt'] ?? '').toString(),
      updatedAt: (json['updatedAt'] ?? '').toString(),
      active: json['active'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'createdAt': createdAt,
        'updatedAt': updatedAt,
        'active': active,
      };
}

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    this.engine,
    this.streaming = false,
    this.via,
  });

  final String role;
  String content;
  String? engine;
  bool streaming;
  /// `voice` for quick-voice turns; null for typed chat.
  final String? via;

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      role: (json['role'] ?? '').toString(),
      content: (json['content'] ?? '').toString(),
      engine: json['engine']?.toString(),
      via: json['via']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (engine != null && engine!.isNotEmpty) 'engine': engine,
        if (via != null && via!.isNotEmpty) 'via': via,
      };
}

class ChatStreamEvent {
  ChatStreamEvent({
    required this.type,
    this.text = '',
    this.engine,
    this.error,
    this.sessionId,
    this.phase,
    this.code,
    this.hint,
    this.pcm,
    this.sampleRate,
    this.audioFormat,
    this.codec,
  });

  final String type;
  final String text;
  final String? engine;
  final String? error;
  final String? sessionId;
  final String? phase;
  final String? code;
  final String? hint;
  final Uint8List? pcm;
  final int? sampleRate;
  /// `pcm` or `mp3` (book voice SSE).
  final String? audioFormat;
  /// `gzip` when PCM payload is compressed.
  final String? codec;

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
      Uint8List? pcm;
      final pcmRaw = json['pcm'];
      final audioRaw = json['audio'];
      if (pcmRaw is String && pcmRaw.isNotEmpty) {
        pcm = base64Decode(pcmRaw);
      } else if (audioRaw is String && audioRaw.isNotEmpty) {
        pcm = base64Decode(audioRaw);
      }
      return ChatStreamEvent(
        type: (json['type'] ?? '').toString(),
        text: (json['text'] ?? json['answer'] ?? '').toString(),
        engine: json['engine']?.toString(),
        error: json['error']?.toString(),
        sessionId: json['sessionId']?.toString(),
        phase: json['phase']?.toString(),
        code: json['code']?.toString(),
        hint: json['hint']?.toString(),
        pcm: pcm,
        sampleRate: json['rate'] is int ? json['rate'] as int : int.tryParse('${json['rate']}'),
        audioFormat: json['format']?.toString(),
        codec: json['codec']?.toString(),
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

/// Chapter / TOC titles: drop leftover Calibre tags and emphasis markers.
String sanitizeBookDisplayTitle(String title) {
  var out = title.replaceAll(RegExp(r'<[^>]+>', caseSensitive: false), ' ');
  out = out.replaceAll('**', '').replaceAll('__', '').replaceAll(RegExp(r'`+'), '');
  return out.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class BookChapterEntry {
  const BookChapterEntry({
    required this.index,
    required this.file,
    required this.title,
    this.level = 0,
    this.href,
  });

  final int index;
  final String file;
  final String title;
  final int level;
  final String? href;

  factory BookChapterEntry.fromJson(Map<String, dynamic> json) {
    final hrefRaw = (json['href'] ?? '').toString().trim();
    return BookChapterEntry(
      index: (json['index'] as num?)?.toInt() ?? 0,
      file: (json['file'] ?? '').toString(),
      title: sanitizeBookDisplayTitle((json['title'] ?? '').toString()),
      level: (json['level'] as num?)?.toInt() ?? 0,
      href: hrefRaw.isEmpty ? null : hrefRaw,
    );
  }
}

class BookTocEntry {
  BookTocEntry({
    required this.index,
    required this.title,
    this.level = 0,
  });

  final int index;
  final String title;
  final int level;

  factory BookTocEntry.fromJson(Map<String, dynamic> json) {
    return BookTocEntry(
      index: (json['index'] as num?)?.toInt() ?? 0,
      title: sanitizeBookDisplayTitle((json['title'] ?? '').toString()),
      level: (json['level'] as num?)?.toInt() ?? 0,
    );
  }
}

class BookReadingManifest {
  BookReadingManifest({
    required this.bookId,
    required this.title,
    required this.author,
    required this.converter,
    required this.chapters,
    required this.toc,
  });

  final String bookId;
  final String title;
  final String author;
  final String converter;
  final List<BookChapterEntry> chapters;
  final List<BookTocEntry> toc;

  factory BookReadingManifest.fromJson(Map<String, dynamic> json) {
    final chapters = (json['chapters'] as List?) ?? [];
    final tocRaw = (json['toc'] as List?) ?? chapters;
    return BookReadingManifest(
      bookId: (json['bookId'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      author: (json['author'] ?? '').toString(),
      converter: (json['converter'] ?? 'plain').toString(),
      chapters: chapters
          .map((e) => BookChapterEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      toc: tocRaw
          .map((e) => BookTocEntry.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

class BookItem {
  BookItem({
    required this.id,
    required this.filename,
    required this.title,
    required this.author,
    required this.language,
    required this.size,
    required this.modifiedAt,
    required this.hasCover,
  });

  final String id;
  final String filename;
  final String title;
  final String author;
  final String language;
  final int size;
  final String modifiedAt;
  final bool hasCover;

  factory BookItem.fromJson(Map<String, dynamic> json) {
    return BookItem(
      id: (json['id'] ?? '').toString(),
      filename: (json['filename'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      author: (json['author'] ?? '').toString(),
      language: (json['language'] ?? '').toString(),
      size: (json['size'] as num?)?.toInt() ?? 0,
      modifiedAt: (json['modifiedAt'] ?? '').toString(),
      hasCover: json['hasCover'] == true,
    );
  }
}

class CheckoutSyncStatus {
  CheckoutSyncStatus({
    required this.present,
    required this.upToDate,
    required this.syncState,
    required this.behind,
    required this.path,
  });

  final bool present;
  final bool upToDate;
  final String syncState;
  final int behind;
  final String path;

  factory CheckoutSyncStatus.fromJson(Map<String, dynamic> json) {
    return CheckoutSyncStatus(
      present: json['present'] == true,
      upToDate: json['upToDate'] == true,
      syncState: (json['syncState'] ?? '').toString(),
      behind: (json['behind'] as num?)?.toInt() ?? 0,
      path: (json['path'] ?? '').toString(),
    );
  }
}
