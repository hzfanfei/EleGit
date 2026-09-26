import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Night ink. Cinnabar is the one accent. Titles use the bundled Song face.
class Wx {
  static const bg = Color(0xFF100E0C);
  static const surface = Color(0xFF1A1714);
  static const raised = Color(0xFF221E1A);
  static const hairline = Color(0xFF3E362F);
  static const text = Color(0xFFEDEBE6);
  static const muted = Color(0xFF9A958C);
  static const faint = Color(0xFF6B675F);
  static const accent = Color(0xFFCC5648);
  static const onAccent = Color(0xFF1A100C);
  static const serif = 'WenxiangSerif';
  static const danger = Color(0xFFE3A090);
  static const ok = Color(0xFF8A9A7B);

  /// Warm paper tone for long-form reading (slightly lifted from bg).
  static const readerPaper = Color(0xFF121110);
  static const readerInk = Color(0xFFE8E4DC);
  static const readerMuted = Color(0xFF7A756C);

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

  static const inset = 16.0;
  static const pagePadding = EdgeInsets.fromLTRB(inset, 16, inset, 24);
  static const radius = 8.0;
  static const tap = 48.0;
}

ThemeData wenxiangTheme() {
  const textTheme = TextTheme(
    displaySmall: TextStyle(
      fontFamily: Wx.serif,
      fontFamilyFallback: Wx.fontFallback,
      fontSize: 34,
      fontWeight: FontWeight.w600,
      letterSpacing: 1,
      height: 1.2,
      color: Wx.text,
    ),
    headlineMedium: TextStyle(
      fontFamily: Wx.serif,
      fontFamilyFallback: Wx.fontFallback,
      fontSize: 22,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
      height: 1.3,
      color: Wx.text,
    ),
    titleLarge: TextStyle(
      fontFamily: Wx.serif,
      fontFamilyFallback: Wx.fontFallback,
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
      height: 1.35,
      color: Wx.text,
    ),
    titleMedium: TextStyle(
      fontFamily: Wx.serif,
      fontFamilyFallback: Wx.fontFallback,
      fontSize: 16,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.3,
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
        fontFamily: Wx.serif,
        fontFamilyFallback: Wx.fontFallback,
        fontSize: 17,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
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
        borderRadius: BorderRadius.circular(Wx.radius),
        borderSide: const BorderSide(color: Wx.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Wx.radius),
        borderSide: const BorderSide(color: Wx.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Wx.radius),
        borderSide: const BorderSide(color: Wx.accent, width: 1.2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: Wx.accent,
        foregroundColor: Wx.onAccent,
        minimumSize: const Size(64, Wx.tap),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Wx.radius)),
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
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Wx.radius)),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
