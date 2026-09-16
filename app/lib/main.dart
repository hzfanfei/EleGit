import 'package:flutter/material.dart';

import 'screens/shell_page.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
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
