import 'dart:ui';

import 'package:flutter/material.dart';

import 'diagnostics/client_error_log.dart';
import 'screens/shell_page.dart';
import 'theme.dart';
import 'utils/notification_center.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    ClientErrorLog.instance.note(
      message: details.exceptionAsString(),
      stack: details.stack?.toString() ?? '',
      kind: 'flutter',
    );
    if (previous != null) {
      previous(details);
    } else {
      FlutterError.presentError(details);
    }
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ClientErrorLog.instance.note(
      message: error.toString(),
      stack: stack.toString(),
      kind: 'platform',
    );
    return false;
  };
  NotificationCenter.instance.initPlatform().then((_) {
    return NotificationCenter.instance.hydrateFromPrefs();
  }).catchError((Object err) {
    debugPrint('NotificationCenter boot failed: $err');
  });
  runApp(const WenxiangApp());
}

class WenxiangApp extends StatelessWidget {
  const WenxiangApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '问象',
      debugShowCheckedModeBanner: false,
      theme: wenxiangTheme(),
      home: const ShellPage(),
    );
  }
}
