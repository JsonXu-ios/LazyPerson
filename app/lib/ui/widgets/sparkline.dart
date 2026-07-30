/// 自选列表行内迷你走势线（1d 稿每行中间那截线）。
/// 数据用已有的 KlinePayload.bars 收盘价尾段；**取不到日线时不留空白**，
/// 退化成一枚涨跌幅色块（fallbackPct），保证每行右侧节奏一致。
/// 新增文件：lib/ui/widgets/sparkline.dart
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';

class Sparkline extends StatelessWidget {
  /// 最近 N 根收盘价（建议 26）。少于 2 个点即视为无数据。
  final List<double> values;
  final Color color;
  final Size size;

  /// 无数据时用它画色块（通常传 quote.pctChg）。为 null 则画一条静默基线。
  final double? fallbackPct;

  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.size = const Size(62, 24),
    this.fallbackPct,
  });

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) {
      return _Fallback(size: size, color: color, pct: fallbackPct);
    }
    return CustomPaint(
      size: size,
      painter: _SparkPainter(values: values, color: color),
    );
  }
}

/// 无 K 线缓存时的替代：一条 4dp 强度条 + 幅度文字，宽度按 |pct| 映射（3% 满格）。
class _Fallback extends StatelessWidget {
  final Size size;
  final Color color;
  final double? pct;

  const _Fallback({required this.size, required this.color, this.pct});

  @override
  Widget build(BuildContext context) {
    if (pct == null) {
      return SizedBox.fromSize(
        size: size,
        child: Center(
          child: Container(
            height: 1,
            width: size.width * 0.6,
            color: AppColors.textDim.withValues(alpha: 0.5),
          ),
        ),
      );
    }
    final ratio = (pct!.abs() / 3).clamp(0.12, 1.0);
    return SizedBox.fromSize(
      size: size,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${pct! >= 0 ? '+' : ''}${pct!.toStringAsFixed(2)}',
            textAlign: TextAlign.right,
            style: mono(
                size: FontSize.badge, color: color, weight: FontWeight.w600),
          ),
          const SizedBox(height: 3),
          Align(
            alignment: Alignment.centerRight,
            child: Container(
              height: 4,
              width: size.width * ratio,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(2),
                gradient: LinearGradient(
                  colors: [color.withValues(alpha: 0.15), color],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;

  _SparkPainter({required this.values, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    var min = double.infinity;
    var max = double.negativeInfinity;
    for (final value in values) {
      min = math.min(min, value);
      max = math.max(max, value);
    }
    if (!min.isFinite || !max.isFinite) return;
    final span = max - min == 0 ? 1.0 : max - min;
    final path = Path();
    for (var index = 0; index < values.length; index++) {
      final x = size.width * index / (values.length - 1);
      final y = size.height - 2 - ((values[index] - min) / span) * (size.height - 4);
      index == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 1.3
        ..strokeJoin = StrokeJoin.round
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) =>
      old.values != values || old.color != color;
}
