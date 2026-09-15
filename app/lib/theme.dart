import 'package:flutter/material.dart';

const ink = Color(0xFF101418);
const inkElevated = Color(0xFF1A2128);
const gold = Color(0xFFE4B15A);
const mist = Color(0xFFD7DEE6);

ThemeData wenxiangTheme() {
  final base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    fontFamily: 'sans-serif',
  );
  return base.copyWith(
    scaffoldBackgroundColor: ink,
    colorScheme: const ColorScheme.dark(
      primary: gold,
      onPrimary: Color(0xFF1A1408),
      surface: inkElevated,
      onSurface: mist,
      secondary: Color(0xFF8BA4B8),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: ink,
      foregroundColor: mist,
      elevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: inkElevated,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2C3640)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Color(0xFF2C3640)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: gold),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: gold,
        foregroundColor: const Color(0xFF1A1408),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
  );
}
