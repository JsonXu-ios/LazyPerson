/// HUD 主题（方案 1d）。整体替换原 lib/theme/app_theme.dart。
/// AppColors 的字段名与旧版完全一致，只改色值 —— 全 App 立刻换肤，
/// 无需改动任何 widget。新增字段集中在 “HUD 追加” 区，供发光/描边使用。
library;

import 'package:flutter/material.dart';

abstract final class AppColors {
  // —— 与旧版同名字段（值已改为 HUD 配色）——
  static const background = Color(0xFF050914);
  static const chartBackground = Color(0xFF050914);
  static const panel = Color(0xFF0C1A33);
  static const panelBorder = Color(0xFF1B3255);
  static const grid = Color(0xFF122038);
  static const axisBorder = Color(0xFF1B3255);
  static const text = Color(0xFFE8F0FF);
  static const textMuted = Color(0xFF8FB4E8);
  static const textFaint = Color(0xFF5D7CA8);
  static const rise = Color(0xFFFF4D6D);
  static const fall = Color(0xFF00E5A0);
  static const warn = Color(0xFFFFB84C);
  static const accent = Color(0xFF4CC9FF);
  static const yellowLine = Color(0xFFF6D36B);

  // —— HUD 追加 ——
  /// 顶部渐变起点（Scaffold 用 hudBackgroundGradient）
  static const backgroundTop = Color(0xFF0F2144);

  /// 卡片/浮层描边（20% accent），所有 HUD 容器统一用它
  static Color get hudBorder => accent.withValues(alpha: 0.20);

  /// 选中态描边 + 底色
  static Color get hudBorderActive => accent.withValues(alpha: 0.50);
  static Color get hudFillActive => accent.withValues(alpha: 0.16);

  /// 卡片底色（半透明，压在渐变背景上）
  static Color get hudPanel => const Color(0xFF091224).withValues(alpha: 0.70);

  /// 次级图例文字
  static const textDim = Color(0xFF41577A);

  /// 副图线色（MACD DIF / DEA、LON / LONMA）
  static const difLine = Color(0xFF4CC9FF);
  static const deaLine = Color(0xFFFFB84C);
  static const lonLine = Color(0xFFE8F0FF);
  static const lonmaLine = Color(0xFFFFB84C);
}

/// 全屏背景渐变（Scaffold 外层 Container 用它，替代纯色 scaffoldBackgroundColor）
const hudBackgroundGradient = RadialGradient(
  center: Alignment(-0.55, -1.0),
  radius: 1.5,
  colors: [AppColors.backgroundTop, AppColors.background],
  stops: [0.0, 0.62],
);

/// 字号标度：按“用途”命名的上限值，411dp 宽下实测舒适。
/// widget 里不要再写裸数字，否则各屏字号会再次跑偏、密到看不清。
/// 列表底部留白：底部导航栏(58) + 凸起圆钮溢出的一半(约16) + 余量。
/// 各页列表的 padding.bottom 用它，避免最后一项被导航挡住。
const bottomNavSafePadding = 96.0;

abstract final class FontSize {
  /// 主屏标的名
  static const symbolName = 21.0;

  /// 现价（发光大字）
  static const price = 30.0;

  /// 卡片/列表项的名称
  static const cardTitle = 15.0;

  /// 屏标题、浮层标题
  static const screenTitle = 16.0;

  /// 涨跌幅与其它次要数字
  static const secondaryNumber = 13.0;

  /// 表格内数字
  static const tableNumber = 12.0;

  /// OHLC 条、副图图例、代码副行
  static const legend = 11.0;

  /// 全大写英文装饰标签（务必配 letterSpacing）
  static const capsLabel = 9.0;

  /// 角标（涨停、形态等）
  static const badge = 10.0;

  /// 中文正文与按钮
  static const body = 12.0;

  /// 次要中文说明
  static const caption = 11.5;
}

/// 数字统一等宽 + tabular figures：所有价格/百分比/日期都用它，
/// 避免跳动（1d 稿里全部数字均为等宽）。
const hudMono = TextStyle(
  fontFamily: 'IBMPlexMono',
  fontFeatures: [FontFeature.tabularFigures()],
);

TextStyle mono({
  double size = 11,
  Color color = AppColors.text,
  FontWeight weight = FontWeight.w500,
  double letterSpacing = 0,
}) =>
    hudMono.copyWith(
      fontSize: size,
      color: color,
      fontWeight: weight,
      letterSpacing: letterSpacing,
    );

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
      backgroundColor: Colors.transparent,
      foregroundColor: AppColors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accent,
        side: BorderSide(color: AppColors.hudBorderActive),
        backgroundColor: AppColors.hudFillActive,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      ),
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: AppColors.panel,
      contentTextStyle: const TextStyle(color: AppColors.text),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(
      color: AppColors.warn,
      linearTrackColor: AppColors.grid,
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
