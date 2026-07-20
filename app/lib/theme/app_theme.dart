/// 深色终端风主题，配色对齐网页版 styles.css / KlineChart.tsx。
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  static const background = Color(0xFF080D16);
  static const chartBackground = Color(0xFF070B12);
  static const panel = Color(0xFF101722);
  static const panelBorder = Color(0xFF2A3850);
  static const grid = Color(0xFF172033);
  static const axisBorder = Color(0xFF28354A);
  static const text = Color(0xFFD6DEEA);
  static const textMuted = Color(0xFF8F9BB0);
  static const textFaint = Color(0xFF76849A);
  static const rise = Color(0xFFF24D4D);
  static const fall = Color(0xFF00A884);
  static const warn = Color(0xFFF2C94C);
  static const accent = Color(0xFF38BDF8);
  static const yellowLine = Color(0xFFF6D36B);
}

ThemeData buildAppTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.background,
    colorScheme: const ColorScheme.dark(
      surface: AppColors.panel,
      primary: AppColors.accent,
      secondary: AppColors.warn,
      error: AppColors.rise,
    ),
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      bodyColor: AppColors.text,
      displayColor: AppColors.text,
    ),
    dividerColor: AppColors.panelBorder,
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.background,
      foregroundColor: AppColors.text,
      elevation: 0,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: AppColors.panel,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: AppColors.panel,
      contentTextStyle: TextStyle(color: AppColors.text),
    ),
  );
}

/// 解析 "#rrggbb" 颜色（线位颜色配置存储格式与网页版一致）
Color colorFromHex(String hex) {
  var clean = hex.replaceFirst('#', '');
  if (clean.length == 6) clean = 'FF$clean';
  return Color(int.tryParse(clean, radix: 16) ?? 0xFFF6D36B);
}

String hexFromColor(Color color) {
  final argb = color.toARGB32();
  return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}
