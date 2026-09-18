import '../models.dart';

/// Where the reader was when a message was sent.
class BookReadingPlace {
  const BookReadingPlace({this.chapter = '', this.epubCfi});

  final String chapter;
  final String? epubCfi;

  BookReadingPlace copyWith({String? chapter, String? epubCfi}) {
    return BookReadingPlace(
      chapter: chapter ?? this.chapter,
      epubCfi: epubCfi ?? this.epubCfi,
    );
  }

  factory BookReadingPlace.fromJson(Map<String, dynamic> json) {
    return BookReadingPlace(
      chapter: (json['chapter'] ?? '').toString(),
      epubCfi: json['epubCfi']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'chapter': chapter,
        if (epubCfi != null && epubCfi!.isNotEmpty) 'epubCfi': epubCfi,
      };
}

/// Stable bucket id: one conversation thread per chapter (reading section).
String bookAnchorId(BookReadingPlace place) {
  final chapter = place.chapter.trim();
  if (chapter.isNotEmpty) {
    return _slug(chapter).isEmpty ? 'chapter' : _slug(chapter);
  }
  final cfi = place.epubCfi?.trim() ?? '';
  if (cfi.isNotEmpty) {
    return 'cfi_${cfi.hashCode.abs().toRadixString(36)}';
  }
  return 'start';
}

String _slug(String input) {
  final trimmed = input.trim().toLowerCase();
  if (trimmed.isEmpty) return '';
  final buf = StringBuffer();
  for (final rune in trimmed.runes) {
    final c = String.fromCharCode(rune);
    if (RegExp(r'[\w\u4e00-\u9fff]').hasMatch(c)) {
      buf.write(c);
    } else if (c == ' ' || c == '-') {
      buf.write('_');
    }
  }
  var s = buf.toString().replaceAll(RegExp(r'_+'), '_');
  if (s.length > 64) s = s.substring(0, 64);
  return s;
}

class BookAnchorChat {
  BookAnchorChat({
    required this.id,
    required this.place,
    required this.messages,
    required this.updatedAt,
  });

  final String id;
  final BookReadingPlace place;
  final List<ChatMessage> messages;
  final String updatedAt;

  factory BookAnchorChat.fromJson(Map<String, dynamic> json) {
    final placeRaw = json['place'];
    final place = placeRaw is Map
        ? BookReadingPlace.fromJson(Map<String, dynamic>.from(placeRaw))
        : BookReadingPlace(chapter: (json['chapter'] ?? '').toString());
    final msgs = ((json['messages'] as List?) ?? [])
        .whereType<Map>()
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m)))
        .toList();
    return BookAnchorChat(
      id: (json['id'] ?? bookAnchorId(place)).toString(),
      place: place,
      messages: msgs,
      updatedAt: (json['updatedAt'] ?? '').toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'place': place.toJson(),
        'chapter': place.chapter,
        'messages': messages.map((m) => m.toJson()).toList(),
        'updatedAt': updatedAt,
      };
}

class BookChatStore {
  BookChatStore({
    required this.sessionId,
    required this.activeAnchorId,
    required this.anchors,
  });

  final String? sessionId;
  final String? activeAnchorId;
  final Map<String, BookAnchorChat> anchors;

  factory BookChatStore.empty() => BookChatStore(
        sessionId: null,
        activeAnchorId: null,
        anchors: const {},
      );

  factory BookChatStore.fromJson(Map<String, dynamic> json) {
    final anchors = <String, BookAnchorChat>{};
    final raw = json['anchors'];
    if (raw is Map) {
      raw.forEach((key, value) {
        if (value is! Map) return;
        final anchor = BookAnchorChat.fromJson(Map<String, dynamic>.from(value));
        anchors[anchor.id] = anchor;
      });
    }
    return BookChatStore(
      sessionId: json['sessionId']?.toString(),
      activeAnchorId: json['activeAnchorId']?.toString(),
      anchors: anchors,
    );
  }

  Map<String, dynamic> toJson() => {
        if (sessionId != null && sessionId!.isNotEmpty) 'sessionId': sessionId,
        if (activeAnchorId != null && activeAnchorId!.isNotEmpty) 'activeAnchorId': activeAnchorId,
        'anchors': anchors.map((key, value) => MapEntry(key, value.toJson())),
      };

  BookChatStore upsertAnchorMessages({
    required String anchorId,
    required BookReadingPlace place,
    required List<ChatMessage> messages,
    String? updatedAt,
  }) {
    final next = Map<String, BookAnchorChat>.from(anchors);
    next[anchorId] = BookAnchorChat(
      id: anchorId,
      place: place,
      messages: List<ChatMessage>.from(messages),
      updatedAt: updatedAt ?? DateTime.now().toUtc().toIso8601String(),
    );
    return BookChatStore(
      sessionId: sessionId,
      activeAnchorId: anchorId,
      anchors: next,
    );
  }

  List<ChatMessage> messagesForAnchor(String anchorId) {
    return List<ChatMessage>.from(anchors[anchorId]?.messages ?? const []);
  }

  String? lastAssistantPeek(String anchorId) {
    final list = anchors[anchorId]?.messages ?? const [];
    for (var i = list.length - 1; i >= 0; i--) {
      if (list[i].role == 'assistant' && list[i].content.trim().isNotEmpty) {
        return list[i].content;
      }
    }
    return null;
  }

  bool get hasAnyMessages => anchors.values.any((a) => a.messages.isNotEmpty);

  BookChatStore removeAnchor(String anchorId) {
    if (!anchors.containsKey(anchorId)) return this;
    final next = Map<String, BookAnchorChat>.from(anchors)..remove(anchorId);
    final active = activeAnchorId == anchorId ? null : activeAnchorId;
    return BookChatStore(sessionId: sessionId, activeAnchorId: active, anchors: next);
  }

  BookChatStore clearAnchors() {
    return BookChatStore(sessionId: sessionId, activeAnchorId: null, anchors: const {});
  }

  BookChatStore deleteTurn(String anchorId, int userMessageIndex) {
    final anchor = anchors[anchorId];
    if (anchor == null) return this;
    final msgs = List<ChatMessage>.from(anchor.messages);
    if (userMessageIndex < 0 || userMessageIndex >= msgs.length) return this;
    if (msgs[userMessageIndex].role != 'user') return this;
    var end = userMessageIndex + 1;
    while (end < msgs.length && msgs[end].role != 'user') {
      end++;
    }
    msgs.removeRange(userMessageIndex, end);
    if (msgs.isEmpty) return removeAnchor(anchorId);
    return upsertAnchorMessages(
      anchorId: anchorId,
      place: anchor.place,
      messages: msgs,
    );
  }
}

/// One user question and its replies within a chapter anchor.
class BookQaTurn {
  BookQaTurn({
    required this.anchorId,
    required this.chapter,
    required this.userMessageIndex,
    required this.user,
    required this.replies,
    required this.updatedAt,
  });

  final String anchorId;
  final String chapter;
  final int userMessageIndex;
  final ChatMessage user;
  final List<ChatMessage> replies;
  final String updatedAt;
}

List<BookQaTurn> listAllBookQaTurns(BookChatStore store) {
  final out = <BookQaTurn>[];
  final anchors = store.anchors.values.toList()
    ..sort((a, b) => a.updatedAt.compareTo(b.updatedAt));
  for (final anchor in anchors) {
    final chapter = anchor.place.chapter.trim().isEmpty ? '未标注章节' : anchor.place.chapter.trim();
    for (var i = 0; i < anchor.messages.length; i++) {
      if (anchor.messages[i].role != 'user') continue;
      final replies = <ChatMessage>[];
      var j = i + 1;
      while (j < anchor.messages.length && anchor.messages[j].role != 'user') {
        replies.add(anchor.messages[j]);
        j++;
      }
      out.add(BookQaTurn(
        anchorId: anchor.id,
        chapter: chapter,
        userMessageIndex: i,
        user: anchor.messages[i],
        replies: replies,
        updatedAt: anchor.updatedAt,
      ));
    }
  }
  return out;
}
