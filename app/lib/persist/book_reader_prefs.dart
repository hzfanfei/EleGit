import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderThemeMode { light, dark, sepia }

enum ReaderNavMode { scroll, tapTurn }

class ReaderPalette {
  const ReaderPalette({
    required this.paper,
    required this.ink,
    required this.muted,
    required this.chromeFade,
  });

  final Color paper;
  final Color ink;
  final Color muted;
  final Color chromeFade;

  static ReaderPalette forMode(ReaderThemeMode mode) {
    switch (mode) {
      case ReaderThemeMode.light:
        return const ReaderPalette(
          paper: Color(0xFFF7F4EE),
          ink: Color(0xFF2C2824),
          muted: Color(0xFF7A7368),
          chromeFade: Color(0xFFF7F4EE),
        );
      case ReaderThemeMode.sepia:
        return const ReaderPalette(
          paper: Color(0xFFE6EDDF),
          ink: Color(0xFF2A3328),
          muted: Color(0xFF5C6B52),
          chromeFade: Color(0xFFE6EDDF),
        );
      case ReaderThemeMode.dark:
        return const ReaderPalette(
          paper: Color(0xFF121110),
          ink: Color(0xFFE8E4DC),
          muted: Color(0xFF7A756C),
          chromeFade: Color(0xFF0C0D0F),
        );
    }
  }
}

class ReaderSettings {
  const ReaderSettings({
    this.theme = ReaderThemeMode.dark,
    this.fontSize = 19,
    this.lineHeight = 1.72,
    this.horizontalPadding = 22,
    this.navMode = ReaderNavMode.scroll,
  });

  final ReaderThemeMode theme;
  final double fontSize;
  final double lineHeight;
  final double horizontalPadding;
  final ReaderNavMode navMode;

  ReaderPalette get palette => ReaderPalette.forMode(theme);

  ReaderSettings copyWith({
    ReaderThemeMode? theme,
    double? fontSize,
    double? lineHeight,
    double? horizontalPadding,
    ReaderNavMode? navMode,
  }) {
    return ReaderSettings(
      theme: theme ?? this.theme,
      fontSize: fontSize ?? this.fontSize,
      lineHeight: lineHeight ?? this.lineHeight,
      horizontalPadding: horizontalPadding ?? this.horizontalPadding,
      navMode: navMode ?? this.navMode,
    );
  }

  factory ReaderSettings.fromJson(Map<String, dynamic> json) {
    final themeRaw = json['theme']?.toString() ?? 'dark';
    ReaderThemeMode theme;
    switch (themeRaw) {
      case 'light':
        theme = ReaderThemeMode.light;
        break;
      case 'sepia':
        theme = ReaderThemeMode.sepia;
        break;
      default:
        theme = ReaderThemeMode.dark;
    }
    final navRaw = json['navMode']?.toString() ?? 'scroll';
    return ReaderSettings(
      theme: theme,
      fontSize: (json['fontSize'] as num?)?.toDouble().clamp(15, 28) ?? 19,
      lineHeight: (json['lineHeight'] as num?)?.toDouble().clamp(1.35, 2.1) ?? 1.72,
      horizontalPadding: (json['horizontalPadding'] as num?)?.toDouble().clamp(8, 40) ?? 22,
      navMode: navRaw == 'scroll' ? ReaderNavMode.scroll : ReaderNavMode.tapTurn,
    );
  }

  Map<String, dynamic> toJson() => {
        'theme': theme.name,
        'fontSize': fontSize,
        'lineHeight': lineHeight,
        'horizontalPadding': horizontalPadding,
        'navMode': navMode == ReaderNavMode.scroll ? 'scroll' : 'tapTurn',
      };
}

class BookReaderPrefs {
  BookReaderPrefs(this.prefs);

  final SharedPreferences prefs;
  static const _key = 'wx.readerSettings';

  ReaderSettings load() {
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return const ReaderSettings();
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const ReaderSettings();
      return ReaderSettings.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return const ReaderSettings();
    }
  }

  Future<void> save(ReaderSettings settings) {
    return prefs.setString(_key, jsonEncode(settings.toJson()));
  }
}
