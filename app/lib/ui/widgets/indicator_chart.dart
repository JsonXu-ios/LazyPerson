/// MACD / LON 副图，显示规则对齐 frontend/src/components/IndicatorTabs.tsx。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/hud.dart';
import '../../utils/format.dart';

class IndicatorPanel extends StatelessWidget {
  final KlinePayload? kline;
  final int? hoverIndex;

  const IndicatorPanel({super.key, required this.kline, this.hoverIndex});

  @override
  Widget build(BuildContext context) {
    final macd = kline?.indicators['macd'] ?? const {};
    final lon = kline?.indicators['lon'] ?? const {};
    final count = kline?.bars.length ?? 0;
    return Column(
      children: [
        _IndicatorBlock(
          title: 'MACD',
          count: count,
          hoverIndex: hoverIndex,
          lines: [
            _LineSeries('DIF', macd['dif'] ?? const [], AppColors.difLine),
            _LineSeries('DEA', macd['dea'] ?? const [], AppColors.deaLine),
          ],
          histogram: macd['hist'] ?? const [],
        ),
        const SizedBox(height: 8),
        // 东财龙系长线画法：对零轴红绿柱（正红负绿）+ LON 白线 + LONMA 均线，
        // 对齐 IndicatorTabs.tsx 的 LON 配置
        _IndicatorBlock(
          title: 'LON',
          count: count,
          hoverIndex: hoverIndex,
          lines: [
            _LineSeries('LON', lon['lon'] ?? const [], AppColors.lonLine),
            _LineSeries('LONMA', lon['lonma'] ?? const [], AppColors.lonmaLine),
          ],
          histogram: lon['lon'] ?? const [],
        ),
      ],
    );
  }
}

class _LineSeries {
  final String name;
  final List<double?> values;
  final Color color;

  const _LineSeries(this.name, this.values, this.color);
}

class _IndicatorBlock extends StatelessWidget {
  final String title;
  final int count;
  final List<_LineSeries> lines;
  final List<double?> histogram;
  final int? hoverIndex;

  const _IndicatorBlock({
    required this.title,
    required this.count,
    required this.lines,
    required this.histogram,
    this.hoverIndex,
  });

  /// 标题行展示的当前值：有十字线取该位，否则取最后一个有效值
  double? _valueOf(_LineSeries line) {
    final values = line.values;
    if (values.isEmpty) return null;
    final index = hoverIndex;
    if (index != null && index < values.length) return values[index];
    for (var i = values.length - 1; i >= 0; i--) {
      final value = values[i];
      if (value != null && !value.isNaN) return value;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      child: HudPanel(
        radius: 10,
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Row(
                children: [
                  Text(title,
                      style: mono(
                          size: FontSize.capsLabel,
                          color: AppColors.textMuted,
                          weight: FontWeight.w600,
                          letterSpacing: 1.4)),
                  const Spacer(),
                  for (final line in lines) ...[
                    Text('${line.name} ${formatNumber(_valueOf(line))}',
                        style: mono(size: FontSize.legend, color: line.color)),
                    const SizedBox(width: 10),
                  ],
                ],
              ),
            ),
            Expanded(
              child: CustomPaint(
                size: Size.infinite,
                painter: _IndicatorPainter(
                  count: count,
                  lines: lines,
                  histogram: histogram,
                  hoverIndex: hoverIndex,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IndicatorPainter extends CustomPainter {
  final int count;
  final List<_LineSeries> lines;
  final List<double?> histogram;
  final int? hoverIndex;

  _IndicatorPainter({
    required this.count,
    required this.lines,
    required this.histogram,
    this.hoverIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (count == 0) return;
    var minValue = double.infinity;
    var maxValue = double.negativeInfinity;
    void scan(List<double?> values) {
      for (final value in values) {
        if (value == null || value.isNaN) continue;
        minValue = math.min(minValue, value);
        maxValue = math.max(maxValue, value);
      }
    }

    scan(histogram);
    for (final line in lines) {
      scan(line.values);
    }
    if (!minValue.isFinite || !maxValue.isFinite) return;
    minValue = math.min(minValue, 0);
    maxValue = math.max(maxValue, 0);
    if (maxValue == minValue) maxValue = minValue + 1;

    final barWidth = size.width / count;
    double toY(double value) =>
        size.height * (1 - (value - minValue) / (maxValue - minValue));

    // 零轴
    final zeroY = toY(0);
    canvas.drawLine(
      Offset(0, zeroY),
      Offset(size.width, zeroY),
      Paint()
        ..color = AppColors.grid
        ..strokeWidth = 1,
    );

    // 柱：>=0 红 / <0 绿（对齐网页版 coloredBars）
    final bodyWidth = math.max(barWidth * 0.6, 1.0);
    for (var index = 0; index < count && index < histogram.length; index++) {
      final value = histogram[index];
      if (value == null || value.isNaN) continue;
      final x = barWidth * index + barWidth / 2;
      final paint = Paint()
        ..color = value >= 0 ? AppColors.rise : AppColors.fall;
      canvas.drawRect(
        Rect.fromLTRB(x - bodyWidth / 2, math.min(zeroY, toY(value)),
            x + bodyWidth / 2, math.max(zeroY, toY(value))),
        paint,
      );
    }

    // 线（发光）
    for (final line in lines) {
      final path = Path();
      var started = false;
      for (var index = 0; index < count && index < line.values.length; index++) {
        final value = line.values[index];
        if (value == null || value.isNaN) {
          started = false;
          continue;
        }
        final x = barWidth * index + barWidth / 2;
        final y = toY(value);
        if (!started) {
          path.moveTo(x, y);
          started = true;
        } else {
          path.lineTo(x, y);
        }
      }
      drawGlowing(canvas, line.color, (p) => canvas.drawPath(path, p),
          sigma: 2, alpha: 0.4, strokeWidth: 1.5);
    }

    if (hoverIndex != null && hoverIndex! < count) {
      final x = barWidth * hoverIndex! + barWidth / 2;
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        Paint()
          ..color = AppColors.textMuted.withValues(alpha: 0.8)
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _IndicatorPainter oldDelegate) {
    return oldDelegate.count != count ||
        oldDelegate.histogram != histogram ||
        oldDelegate.lines != lines ||
        oldDelegate.hoverIndex != hoverIndex;
  }
}
