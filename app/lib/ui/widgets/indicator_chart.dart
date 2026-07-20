/// MACD / LON 副图，显示规则对齐 frontend/src/components/IndicatorTabs.tsx。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../theme/app_theme.dart';

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
            _LineSeries('DIF', macd['dif'] ?? const [], AppColors.accent),
            _LineSeries('DEA', macd['dea'] ?? const [], AppColors.warn),
          ],
          histogram: macd['hist'] ?? const [],
        ),
        const SizedBox(height: 6),
        _IndicatorBlock(
          title: 'LON',
          count: count,
          hoverIndex: hoverIndex,
          lines: [
            _LineSeries('LONMA', lon['lonma'] ?? const [], AppColors.accent),
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

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 110,
      decoration: BoxDecoration(
        color: AppColors.chartBackground,
        border: Border.all(color: AppColors.grid),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 8, top: 4),
            child: Row(
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 10),
                for (final line in lines) ...[
                  Container(width: 8, height: 2, color: line.color),
                  const SizedBox(width: 3),
                  Text(line.name,
                      style: const TextStyle(
                          color: AppColors.textFaint, fontSize: 9)),
                  const SizedBox(width: 8),
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

    // 线
    for (final line in lines) {
      final paint = Paint()
        ..color = line.color
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;
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
      canvas.drawPath(path, paint);
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
