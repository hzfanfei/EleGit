import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Quiet graphite workspace. One warm-clay accent — not Material purple, not AI gold.
class Wx {
  static const bg = Color(0xFF0C0D0F);
  static const surface = Color(0xFF16181C);
  static const raised = Color(0xFF1C1F24);
  static const hairline = Color(0xFF2C3036);
  static const text = Color(0xFFEDEBE6);
  static const muted = Color(0xFF9A958C);
  static const faint = Color(0xFF6B675F);
  static const accent = Color(0xFFC9845A);
  static const onAccent = Color(0xFF1A120C);
  static const danger = Color(0xFFD27A6C);
  static const ok = Color(0xFF8A9A7B);

  /// System UI + CJK. Do not name an unregistered webfont — CanvasKit will
  /// double-paint Latin glyphs if the family is not in Flutter's font registry.
  static const fontFallback = [
    'PingFang SC',
    'Hiragino Sans GB',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
    'sans-serif',
  ];

  static const pagePadding = EdgeInsets.fromLTRB(24, 16, 24, 24);
  static const radius = 16.0;
  static const tap = 48.0;
}

ThemeData wenxiangTheme() {
  const textTheme = TextTheme(
    displaySmall: TextStyle(
      fontSize: 34,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.7,
      height: 1.15,
      color: Wx.text,
    ),
    headlineMedium: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
      height: 1.25,
      color: Wx.text,
    ),
    titleLarge: TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      height: 1.3,
      color: Wx.text,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      height: 1.35,
      color: Wx.text,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w400,
      height: 1.55,
      color: Wx.text,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w400,
      height: 1.5,
      color: Wx.muted,
    ),
    labelLarge: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.1,
      color: Wx.onAccent,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      letterSpacing: 0.2,
      height: 1.3,
      color: Wx.faint,
    ),
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamilyFallback: Wx.fontFallback,
    textTheme: textTheme,
    primaryTextTheme: textTheme,
  );

  return base.copyWith(
    scaffoldBackgroundColor: Wx.bg,
    canvasColor: Wx.bg,
    dividerColor: Wx.hairline,
    colorScheme: const ColorScheme.dark(
      primary: Wx.accent,
      onPrimary: Wx.onAccent,
      surface: Wx.surface,
      onSurface: Wx.text,
      secondary: Wx.muted,
      onSecondary: Wx.text,
      error: Wx.danger,
      onError: Wx.text,
      outline: Wx.hairline,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Wx.bg,
      foregroundColor: Wx.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 8,
      titleTextStyle: TextStyle(
        fontFamilyFallback: Wx.fontFallback,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: Wx.text,
      ),
      iconTheme: IconThemeData(color: Wx.text, size: 22),
      systemOverlayStyle: SystemUiOverlayStyle.light,
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(Wx.tap, Wx.tap),
        foregroundColor: Wx.text,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Wx.surface,
      hintStyle: const TextStyle(color: Wx.faint, fontSize: 15, height: 1.4),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Wx.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Wx.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Wx.accent, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Wx.accent,
        foregroundColor: Wx.onAccent,
        minimumSize: const Size(64, Wx.tap),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        textStyle: const TextStyle(
          fontFamilyFallback: Wx.fontFallback,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: Wx.accent,
        minimumSize: const Size(64, 44),
        textStyle: const TextStyle(
          fontFamilyFallback: Wx.fontFallback,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: Wx.accent,
      linearMinHeight: 2,
      linearTrackColor: Wx.hairline,
      circularTrackColor: Wx.hairline,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: Wx.raised,
      contentTextStyle: const TextStyle(color: Wx.text, height: 1.4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
