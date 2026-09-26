import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

import '../api/wenxiang_api.dart';
import '../persist/chat_backfill.dart';
import 'background_sync.dart';

/// A single inbox notification item delivered by the companion.
class InboxItem {
  InboxItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.body,
    required this.createdAt,
    required this.read,
    this.sessionId,
    this.question,
    this.answer,
    this.owner,
    this.repo,
    this.bookId,
  });

  final String id;
  final String kind;
  final String title;
  final String body;
  final DateTime createdAt;
  final bool read;
  final String? sessionId;
  final String? question;
  final String? answer;
  final String? owner;
  final String? repo;
  final String? bookId;

  factory InboxItem.fromJson(Map<String, dynamic> json) {
    DateTime parseCreated() {
      final raw = json['createdAt'] ?? json['created_at'];
      if (raw is String) return DateTime.tryParse(raw) ?? DateTime.now();
      return DateTime.now();
    }

    return InboxItem(
      id: (json['id'] ?? '').toString(),
      kind: (json['kind'] ?? 'agent-notification').toString(),
      title: (json['title'] ?? '问象').toString(),
      body: (json['body'] ?? '').toString(),
      createdAt: parseCreated(),
      read: json['read'] == true,
      sessionId: json['sessionId']?.toString(),
      question: json['question']?.toString(),
      answer: json['answer']?.toString(),
      owner: json['owner']?.toString(),
      repo: json['repo']?.toString(),
      bookId: json['bookId']?.toString(),
    );
  }
}

/// Android-only local system notifications for the Wenxiang app.
///
/// Listens to the companion's `/v1/notifications` WebSocket and surfaces each
/// inbox item as a `Notification` toast. Falls back to a one-shot `GET
/// /v1/inbox` fetch on connect / app resume so that anything queued while the
/// socket was offline (app killed, OS recents) still surfaces once the user
/// comes back.
class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter instance = NotificationCenter._();

  static const _channelId = 'wenxiang_inbox';
  static const _channelName = '问书通知';
  static const _channelDesc = '问书后台任务完成时推送到通知中心';
  static const _enabledPrefKey = 'wenxiang_notifications_enabled';

  WenxiangApi? _api;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _channelSub;
  Timer? _retryTimer;
  Timer? _heartbeatTimer;
  bool _permissionGranted = false;
  bool _starting = false;

  final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);
  final ValueNotifier<Connectivity> connectivity =
      ValueNotifier<Connectivity>(Connectivity.idle);

  /// Initialise the platform plugin. Safe to call multiple times.
  Future<void> initPlatform() async {
    if (!Platform.isAndroid) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      );
      await FlutterLocalNotificationsPlugin().initialize(settings);
    } catch (err) {
      debugPrint('NotificationCenter init failed: $err');
    }
  }

  /// Restore the persisted enabled preference. Call once at app boot.
  Future<void> hydrateFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_enabledPrefKey) ?? false;
  }

  /// Begin (or stop) live notification delivery.
  Future<void> setEnabled(WenxiangApi api, {required bool want}) async {
    _api = api;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledPrefKey, want);
    enabled.value = want;
    if (want) {
      if (!await _ensurePermission()) return;
      await BackgroundSync.acquire();
      await connect();
      await fetchAndShowUnread();
    } else {
      await BackgroundSync.release();
      await disconnect();
    }
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) {
      _permissionGranted = true;
      return true;
    }
    try {
      final plugin = FlutterLocalNotificationsPlugin()
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      _permissionGranted = await plugin?.requestNotificationsPermission() ?? true;
      return _permissionGranted;
    } catch (err) {
      debugPrint('Permission request failed: $err');
      return false;
    }
  }

  /// Open the WebSocket and start showing inbox items as notifications.
  Future<void> connect() async {
    if (!Platform.isAndroid) return;
    final api = _api;
    if (api == null) return;
    if (_starting || _channel != null) return;
    _starting = true;
    try {
      final uri = _wsUri(api, '/v1/notifications');
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _channelSub = channel.stream.listen(
        _onMessage,
        onDone: _onDone,
        onError: (Object e) {
          debugPrint('NotificationCenter ws error: $e');
          _onDone();
        },
        cancelOnError: true,
      );
      connectivity.value = Connectivity.connected;
      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        try {
          channel.sink.add('{"type":"ping"}');
        } catch (_) {
          /* socket may already be gone */
        }
      });
    } catch (err) {
      debugPrint('NotificationCenter connect failed: $err');
      connectivity.value = Connectivity.idle;
      _scheduleRetry();
    } finally {
      _starting = false;
    }
  }

  Future<void> disconnect() async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    try {
      await _channelSub?.cancel();
    } catch (_) {}
    _channelSub = null;
    try {
      await _channel?.sink.close(ws_status.normalClosure);
    } catch (_) {}
    _channel = null;
    connectivity.value = Connectivity.idle;
  }

  void _scheduleRetry() {
    if (!enabled.value) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 8), () {
      if (enabled.value) connect();
    });
  }

  Future<void> _onMessage(dynamic raw) async {
    if (raw is! String) return;
    Map<String, dynamic>? payload;
    try {
      payload = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    final type = (payload['type'] ?? '').toString();
    if (type == 'snapshot') {
      final list = (payload['items'] as List?) ?? const [];
      for (final entry in list) {
        if (entry is Map) {
          await _showItem(InboxItem.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
      return;
    }
    if (type == 'inbox') {
      final entry = payload['item'];
      if (entry is Map) {
        await _showItem(InboxItem.fromJson(Map<String, dynamic>.from(entry)));
      }
      return;
    }
    if (type == 'pong' || type == 'ping') {
      return;
    }
  }

  void _onDone() {
    _channel = null;
    _channelSub = null;
    connectivity.value = Connectivity.idle;
    _scheduleRetry();
  }

  Future<void> fetchAndShowUnread() async {
    final api = _api;
    if (api == null) return;
    try {
      final res = await api.fetchInbox();
      final list = (res['items'] as List?) ?? const [];
      var unread = 0;
      for (final entry in list) {
        if (entry is Map) {
          final item = InboxItem.fromJson(Map<String, dynamic>.from(entry));
          if (!item.read) {
            unread++;
            await _showItem(item);
          }
        }
      }
      unreadCount.value = unread;
    } catch (err) {
      debugPrint('fetchInbox failed: $err');
    }
  }

  Future<void> _showItem(InboxItem item) async {
    try {
      await backfillChatFromNotice(
        sessionId: item.sessionId ?? '',
        answer: item.answer ?? '',
        question: item.question ?? '',
        owner: item.owner ?? '',
        repo: item.repo ?? '',
        bookId: item.bookId ?? '',
      );
    } catch (err) {
      debugPrint('Chat backfill failed: $err');
    }
    if (item.read) return;
    if (!Platform.isAndroid) return;
    final plugin = FlutterLocalNotificationsPlugin();
    final details = AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDesc,
      importance: Importance.high,
      priority: Priority.high,
      category: AndroidNotificationCategory.message,
      styleInformation: BigTextStyleInformation(item.body),
    );
    try {
      await plugin.show(
        _stableId(item.id),
        item.title,
        item.body,
        NotificationDetails(android: details),
        payload: item.id,
      );
      final id = item.id.trim();
      if (id.isNotEmpty) {
        await _api?.markInboxRead(id);
      }
    } catch (err) {
      debugPrint('Show notification failed: $err');
    }
  }

  /// Stable, positive 32-bit hash so the OS treats successive inbox items as
  /// the same notification rather than stacking dozens of them.
  int _stableId(String key) {
    var h = 0;
    for (final cu in key.codeUnits) {
      h = (h * 31 + cu) & 0x7fffffff;
    }
    return h == 0 ? 1 : h;
  }

  Uri _wsUri(WenxiangApi api, String path) {
    final root = api.baseUrl.replaceAll(RegExp(r'/$'), '');
    final wsRoot = root.startsWith('https')
        ? root.replaceFirst(RegExp(r'^https'), 'wss')
        : root.replaceFirst(RegExp(r'^http'), 'ws');
    final fullPath = path.startsWith('/') ? path : '/$path';
    return Uri.parse('$wsRoot$fullPath').replace(queryParameters: {
      if (api.apiKey.isNotEmpty) 'key': api.apiKey,
    });
  }
}

enum Connectivity { idle, connected }
