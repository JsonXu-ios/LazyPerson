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

const _majorPalette = [
  '#38bdf8',
  '#f24d4d',
  '#c084fc',
  '#f2a93b',
  '#1f6feb',
  '#00a884',
];

String majorLevelColor(int percent) {
  final index = math.max((percent ~/ 10) - 1, 0) % _majorPalette.length;
  return _majorPalette[index];
}

String majorLevelTextColor(int percent) {
  final color = majorLevelColor(percent);
  return color == '#38bdf8' || color == '#f2a93b' ? '#061016' : '#ffffff';
}

/// 线条颜色：+20%红/+50%蓝/+80%白固定色优先，其余主线用调色板，
/// 细线用用户配置（顺序对齐 KlineChart.tsx::lineColor）
String levelLineColor(AutoLineLevel level, String fallback,
    {int? majorLineStep, double majorLineMinPercent = 0, int majorLineAnchor = 0}) {
  if (level.label == '+20%') return '#f24d4d';
  if (level.label == '+50%') return '#1f6feb';
  if (level.label == '+80%') return '#ffffff';
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
  if (level.label == '+20%' || level.label == '+50%') return '#ffffff';
  if (level.label == '+80%') return '#07111f';
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
