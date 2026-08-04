/// 水平位线的显示规则（颜色/加粗/标签优先级/避让），
/// 移植自 frontend/src/components/KlineChart.tsx 底部的纯函数。
library;

import 'dart:math' as math;

import 'auto_drawing.dart';

/// KlineChart.tsx::isMajorLevel：主线 = anchor 起每 step 一档
/// （A 股 anchor=20 step=30 → 20/50/80/110/…/230）
bool isMajorLevel(AutoLineLevel level,
    {int? majorLineStep, double majorLineMinPercent = 0, int majorLineAnchor = 0}) {
  if (majorLineStep == null || majorLineStep == 0 || level.percent <= 0) {
    return false;
  }
  if (level.percent < math.max(majorLineMinPercent, majorLineAnchor.toDouble())) {
    return false;
  }
  return (level.percent - majorLineAnchor) % majorLineStep == 0;
}

bool isHighlightLevel(AutoLineLevel level,
    {int? majorLineStep, double majorLineMinPercent = 0, int majorLineAnchor = 0}) {
  return isMajorLevel(level,
          majorLineStep: majorLineStep,
          majorLineMinPercent: majorLineMinPercent,
          majorLineAnchor: majorLineAnchor) ||
      level.percent == 0 ||
      level.label == '+20%' ||
      level.label == '+50%' ||
      level.label == '+80%';
}

/// 主线每档固定专属色（A 股 anchor=20 step=30 → 20/50/80/…/230，
/// 与网页版 KlineChart.tsx::majorLevelColor 完全一致）
const majorLevelFixedColors = <int, String>{
  20: '#f24d4d', // 红
  50: '#1f6feb', // 蓝
  80: '#ffffff', // 白
  110: '#c084fc', // 紫
  140: '#f2a93b', // 琥珀
  170: '#00a884', // 绿
  200: '#38bdf8', // 青
  230: '#f472b6', // 玫红
};

/// 固定映射之外的主线档位按同一顺序轮转兜底
const _majorPalette = [
  '#f24d4d',
  '#1f6feb',
  '#ffffff',
  '#c084fc',
  '#f2a93b',
  '#00a884',
  '#38bdf8',
  '#f472b6',
];

/// 浅底色（白/琥珀/青）标签用深色文字，其余用白色
const _lightBackgrounds = {'#ffffff', '#f2a93b', '#38bdf8'};

String majorLevelColor(int percent) {
  final fixed = majorLevelFixedColors[percent];
  if (fixed != null) return fixed;
  final index = math.max((percent ~/ 10) - 1, 0) % _majorPalette.length;
  return _majorPalette[index];
}

String majorLevelTextColor(int percent) =>
    _lightBackgrounds.contains(majorLevelColor(percent))
        ? '#07111f'
        : '#ffffff';

/// 线条颜色：主线（含 +20%/+50%/+80% 特殊位）走固定专属色映射，
/// 细线用用户配置（顺序对齐 KlineChart.tsx::lineColor）
String levelLineColor(AutoLineLevel level, String fallback,
    {int? majorLineStep, double majorLineMinPercent = 0, int majorLineAnchor = 0}) {
  if (level.label == '+20%' || level.label == '+50%' || level.label == '+80%') {
    return majorLevelColor(level.percent);
  }
  if (isMajorLevel(level,
      majorLineStep: majorLineStep,
      majorLineMinPercent: majorLineMinPercent,
      majorLineAnchor: majorLineAnchor)) {
    return majorLevelColor(level.percent);
  }
  return fallback;
}

String levelLabelTextColor(AutoLineLevel level,
    {int? majorLineStep, double majorLineMinPercent = 0, int majorLineAnchor = 0}) {
  if (level.label == '+20%' || level.label == '+50%' || level.label == '+80%') {
    return majorLevelTextColor(level.percent);
  }
  if (isMajorLevel(level,
      majorLineStep: majorLineStep,
      majorLineMinPercent: majorLineMinPercent,
      majorLineAnchor: majorLineAnchor)) {
    return majorLevelTextColor(level.percent);
  }
  return '#07111f';
}

double levelLabelPriority(AutoLineLevel level,
    {int? majorLineStep, double majorLineMinPercent = 0, int majorLineAnchor = 0}) {
  if (level.percent == 0) return 90;
  if (isMajorLevel(level,
      majorLineStep: majorLineStep,
      majorLineMinPercent: majorLineMinPercent,
      majorLineAnchor: majorLineAnchor)) {
    return 80 + math.min(level.percent, 200) / 100;
  }
  if (level.percent % 50 == 0) return 70;
  if (level.percent % 20 == 0) return 60;
  if (level.percent % 10 == 0) return 50;
  return 10;
}

class LevelLabelRow {
  final String key;
  final String label;
  final String color;
  final String textColor;
  final double top;
  final bool highlight;
  final double priority;

  const LevelLabelRow({
    required this.key,
    required this.label,
    required this.color,
    required this.textColor,
    required this.top,
    required this.highlight,
    required this.priority,
  });
}

/// 标签避让：高优先级先占位，间距不足的丢弃
List<LevelLabelRow> avoidCrowdedLevelLabels(List<LevelLabelRow> rows) {
  const minGap = 19.0;
  final sorted = [...rows]..sort((a, b) {
      final byPriority = b.priority.compareTo(a.priority);
      if (byPriority != 0) return byPriority;
      return a.top.compareTo(b.top);
    });
  final kept = <LevelLabelRow>[];
  for (final row in sorted) {
    final gap = row.highlight ? minGap + 4 : minGap;
    final blocked = kept.any((item) =>
        (item.top - row.top).abs() <
        math.max(gap, item.highlight ? minGap + 4 : minGap));
    if (!blocked) kept.add(row);
  }
  kept.sort((a, b) => a.top.compareTo(b.top));
  return kept;
}

/// KlineChart.tsx::shouldUseLogPriceScale
bool shouldUseLogPriceScale(AutoDrawing? autoDrawing) {
  if (autoDrawing == null) return false;
  final base = autoDrawing.base.price;
  final target = autoDrawing.target.price;
  if (!base.isFinite || !target.isFinite || base <= 0) return false;
  return target / base >= 2 || autoDrawing.levels.length >= 28;
}
