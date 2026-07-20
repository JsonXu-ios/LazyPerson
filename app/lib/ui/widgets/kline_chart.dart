/// K 线主图：CustomPaint 自绘蜡烛 + 成交量 + 自动画线叠加 + 长按十字线。
/// 显示规则对齐 frontend/src/components/KlineChart.tsx（固定窗口，不做缩放平移）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../logic/auto_drawing.dart';
import '../../logic/level_rules.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';

class KlineChart extends StatefulWidget {
  final KlinePayload? payload;
  final AutoDrawing? autoDrawing;
  final Map<String, String> lineColors;
  final int? majorLineStep;
  final double majorLineMinPercent;
  final bool showLevelPrices;
  final ValueChanged<int?>? onHoverIndexChanged;
  final int? hoverIndex;

  const KlineChart({
    super.key,
    required this.payload,
    required this.autoDrawing,
    required this.lineColors,
    this.majorLineStep,
    this.majorLineMinPercent = 0,
    this.showLevelPrices = false,
    this.onHoverIndexChanged,
    this.hoverIndex,
  });

  @override
  State<KlineChart> createState() => _KlineChartState();
}

class _KlineChartState extends State<KlineChart> {
  void _updateHover(Offset position, double width) {
    final bars = widget.payload?.bars ?? const <KlineBar>[];
    if (bars.isEmpty) return;
    final plotWidth = width - _KlinePainter.rightAxisWidth;
    final barWidth = plotWidth / bars.length;
    final index = (position.dx / barWidth).floor().clamp(0, bars.length - 1);
    widget.onHoverIndexChanged?.call(index);
  }

  void _clearHover() => widget.onHoverIndexChanged?.call(null);

  @override
  Widget build(BuildContext context) {
    final bars = widget.payload?.bars ?? const <KlineBar>[];
    final hover =
        widget.hoverIndex != null && widget.hoverIndex! < bars.length
            ? bars[widget.hoverIndex!]
            : (bars.isNotEmpty ? bars.last : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _OhlcStrip(bar: hover, isHover: widget.hoverIndex != null),
        Expanded(
          child: bars.isEmpty
              ? const Center(
                  child: Text('暂无K线数据',
                      style:
                          TextStyle(color: AppColors.textFaint, fontSize: 13)))
              : LayoutBuilder(
                  builder: (context, constraints) => GestureDetector(
                    onLongPressStart: (event) =>
                        _updateHover(event.localPosition, constraints.maxWidth),
                    onLongPressMoveUpdate: (event) =>
                        _updateHover(event.localPosition, constraints.maxWidth),
                    onLongPressEnd: (_) => _clearHover(),
                    onTapDown: (event) =>
                        _updateHover(event.localPosition, constraints.maxWidth),
                    onTapUp: (_) => _clearHover(),
                    child: CustomPaint(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                      painter: _KlinePainter(
                        bars: bars,
                        period: widget.payload?.period ?? 'day',
                        autoDrawing: widget.autoDrawing,
                        lineColors: widget.lineColors,
                        majorLineStep: widget.majorLineStep,
                        majorLineMinPercent: widget.majorLineMinPercent,
                        showLevelPrices: widget.showLevelPrices,
                        hoverIndex: widget.hoverIndex,
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _OhlcStrip extends StatelessWidget {
  final KlineBar? bar;
  final bool isHover;

  const _OhlcStrip({required this.bar, required this.isHover});

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: isHover ? AppColors.warn : AppColors.textFaint,
      fontSize: 11,
    );
    final items = [
      if (isHover && bar != null) bar!.time,
      '开 ${formatNumber(bar?.open)}',
      '高 ${formatNumber(bar?.high)}',
      '低 ${formatNumber(bar?.low)}',
      '收 ${formatNumber(bar?.close)}',
      '幅 ${formatPercent(bar?.pctChg)}',
      '量 ${formatNumber(bar?.volume)}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Wrap(
        spacing: 10,
        children: [for (final item in items) Text(item, style: style)],
      ),
    );
  }
}

class _KlinePainter extends CustomPainter {
  static const rightAxisWidth = 52.0;
  static const bottomAxisHeight = 18.0;

  final List<KlineBar> bars;
  final String period;
  final AutoDrawing? autoDrawing;
  final Map<String, String> lineColors;
  final int? majorLineStep;
  final double majorLineMinPercent;
  final bool showLevelPrices;
  final int? hoverIndex;

  late final bool _useLog;
  late final double _minPrice;
  late final double _maxPrice;

  _KlinePainter({
    required this.bars,
    required this.period,
    required this.autoDrawing,
    required this.lineColors,
    required this.majorLineStep,
    required this.majorLineMinPercent,
    required this.showLevelPrices,
    required this.hoverIndex,
  }) {
    _useLog = period == 'day' && shouldUseLogPriceScale(autoDrawing);
    var minPrice = double.infinity;
    var maxPrice = double.negativeInfinity;
    for (final bar in bars) {
      if (bar.low != null) minPrice = math.min(minPrice, bar.low!);
      if (bar.high != null) maxPrice = math.max(maxPrice, bar.high!);
    }
    if (!minPrice.isFinite || !maxPrice.isFinite) {
      minPrice = 0;
      maxPrice = 1;
    }
    if (maxPrice == minPrice) maxPrice = minPrice + 1;
    _minPrice = minPrice;
    _maxPrice = maxPrice;
  }

  double get _plotTopMargin => _useLog ? 0.12 : 0.08;
  double get _plotBottomMargin => _useLog ? 0.16 : 0.12;

  double _scale(double price) =>
      _useLog ? math.log(math.max(price, 1e-9)) : price;

  /// price -> y（对齐 lightweight-charts 的 scaleMargins 语义）
  double _priceToY(double price, double plotHeight) {
    final top = plotHeight * _plotTopMargin;
    final bottom = plotHeight * (1 - _plotBottomMargin);
    final min = _scale(_minPrice);
    final max = _scale(_maxPrice);
    final ratio = max == min ? 0.5 : (_scale(price) - min) / (max - min);
    return bottom - ratio * (bottom - top);
  }

  double _indexToX(int index, double plotWidth) {
    final barWidth = plotWidth / bars.length;
    return barWidth * index + barWidth / 2;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final plotWidth = size.width - rightAxisWidth;
    final plotHeight = size.height - bottomAxisHeight;
    final barWidth = plotWidth / bars.length;

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = AppColors.chartBackground,
    );

    _paintGridAndAxis(canvas, plotWidth, plotHeight);
    _paintVolume(canvas, plotWidth, plotHeight, barWidth);
    _paintCandles(canvas, plotWidth, plotHeight, barWidth);
    if (period == 'day' && autoDrawing != null) {
      _paintLevels(canvas, plotWidth, plotHeight);
      _paintTrendSegments(canvas, plotWidth, plotHeight);
    }
    _paintTimeAxis(canvas, plotWidth, plotHeight);
    if (hoverIndex != null && hoverIndex! < bars.length) {
      _paintCrosshair(canvas, plotWidth, plotHeight, hoverIndex!);
    }
  }

  void _paintGridAndAxis(Canvas canvas, double plotWidth, double plotHeight) {
    final gridPaint = Paint()
      ..color = AppColors.grid
      ..strokeWidth = 1;
    final axisText = _textStyle(AppColors.textFaint, 10);
    const rows = 5;
    for (var i = 0; i <= rows; i++) {
      final ratio = i / rows;
      final y = plotHeight * (_plotTopMargin +
          ratio * (1 - _plotTopMargin - _plotBottomMargin));
      canvas.drawLine(Offset(0, y), Offset(plotWidth, y), gridPaint);
      final min = _scale(_minPrice);
      final max = _scale(_maxPrice);
      final scaled = max - ratio * (max - min);
      final price = _useLog ? math.exp(scaled) : scaled;
      _drawText(canvas, formatFullPrice(price), axisText,
          Offset(plotWidth + 4, y - 6));
    }
    canvas.drawLine(Offset(plotWidth, 0), Offset(plotWidth, plotHeight),
        Paint()..color = AppColors.axisBorder);
  }

  void _paintVolume(
      Canvas canvas, double plotWidth, double plotHeight, double barWidth) {
    var maxVolume = 0.0;
    for (final bar in bars) {
      if (bar.volume != null) maxVolume = math.max(maxVolume, bar.volume!);
    }
    if (maxVolume <= 0) return;
    // 成交量占底部 22%（scaleMargins top 0.78）
    final volumeTop = plotHeight * 0.78;
    final volumeHeight = plotHeight - volumeTop;
    final bodyWidth = math.max(barWidth * 0.7, 1.0);
    for (var index = 0; index < bars.length; index++) {
      final bar = bars[index];
      if (bar.volume == null) continue;
      final up = (bar.close ?? 0) >= (bar.open ?? 0);
      final paint = Paint()
        ..color = (up ? AppColors.rise : AppColors.fall).withValues(alpha: 0.46);
      final height = volumeHeight * (bar.volume! / maxVolume);
      final x = _indexToX(index, plotWidth);
      canvas.drawRect(
        Rect.fromLTWH(x - bodyWidth / 2, plotHeight - height, bodyWidth, height),
        paint,
      );
    }
  }

  void _paintCandles(
      Canvas canvas, double plotWidth, double plotHeight, double barWidth) {
    final bodyWidth = math.max(barWidth * 0.7, 1.0);
    for (var index = 0; index < bars.length; index++) {
      final bar = bars[index];
      if (!bar.hasOhlc) continue;
      final up = bar.close! >= bar.open!;
      final color = up ? AppColors.rise : AppColors.fall;
      final paint = Paint()..color = color;
      final x = _indexToX(index, plotWidth);
      final highY = _priceToY(bar.high!, plotHeight);
      final lowY = _priceToY(bar.low!, plotHeight);
      final openY = _priceToY(bar.open!, plotHeight);
      final closeY = _priceToY(bar.close!, plotHeight);
      canvas.drawLine(Offset(x, highY), Offset(x, lowY),
          paint..strokeWidth = math.max(barWidth * 0.12, 1.0));
      final top = math.min(openY, closeY);
      final bottom = math.max(openY, closeY);
      canvas.drawRect(
        Rect.fromLTWH(x - bodyWidth / 2, top, bodyWidth,
            math.max(bottom - top, 1.0)),
        paint,
      );
    }
  }

  void _paintLevels(Canvas canvas, double plotWidth, double plotHeight) {
    final drawing = autoDrawing!;
    final labelRows = <LevelLabelRow>[];
    for (final level in drawing.levels) {
      final y = _priceToY(level.price, plotHeight);
      if (y < 0 || y > plotHeight) continue;
      final highlight = isHighlightLevel(level,
          majorLineStep: majorLineStep,
          majorLineMinPercent: majorLineMinPercent);
      final colorHex = levelLineColor(
        level,
        lineColors[level.label] ??
            defaultLineColors[level.label] ??
            defaultYellow,
        majorLineStep: majorLineStep,
        majorLineMinPercent: majorLineMinPercent,
      );
      canvas.drawLine(
        Offset(0, y),
        Offset(plotWidth, y),
        Paint()
          ..color = colorFromHex(colorHex)
          ..strokeWidth = highlight ? 3 : 1,
      );
      // 只有 majorLineStep 整数倍（A 股 0/20/40/…%）显示数值标签，其余只画线
      final labelStep = majorLineStep ?? 20;
      if (level.percent % labelStep != 0) continue;
      labelRows.add(LevelLabelRow(
        key: 'auto-${level.label}',
        label: showLevelPrices
            ? '${level.label} ${formatFullPrice(level.price)}'
            : level.label,
        color: colorHex,
        textColor: levelLabelTextColor(level,
            majorLineStep: majorLineStep,
            majorLineMinPercent: majorLineMinPercent),
        top: y,
        highlight: highlight,
        priority: levelLabelPriority(level,
            majorLineStep: majorLineStep,
            majorLineMinPercent: majorLineMinPercent),
      ));
    }

    for (final row in avoidCrowdedLevelLabels(labelRows)) {
      _drawLevelLabel(canvas, row);
    }
  }

  void _drawLevelLabel(Canvas canvas, LevelLabelRow row) {
    final painter = TextPainter(
      text: TextSpan(
        text: row.label,
        style: TextStyle(
          color: colorFromHex(row.textColor),
          fontSize: 10,
          fontWeight: row.highlight ? FontWeight.w700 : FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const paddingH = 4.0;
    const paddingV = 1.5;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH(4, row.top - painter.height / 2 - paddingV,
          painter.width + paddingH * 2, painter.height + paddingV * 2),
      const Radius.circular(3),
    );
    canvas.drawRRect(rect, Paint()..color = colorFromHex(row.color));
    painter.paint(canvas, Offset(4 + paddingH, row.top - painter.height / 2));
  }

  void _paintTrendSegments(Canvas canvas, double plotWidth, double plotHeight) {
    for (final segment in autoDrawing!.trendSegments) {
      final startIndex = _indexForTime(segment.start.time, segment.start.index);
      final endIndex = _indexForTime(segment.end.time, segment.end.index);
      if (startIndex == null || endIndex == null) continue;
      final paint = Paint()
        ..color = segment.direction == AutoTrendDirection.up
            ? AppColors.rise
            : AppColors.fall
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(_indexToX(startIndex, plotWidth),
            _priceToY(segment.start.price, plotHeight)),
        Offset(_indexToX(endIndex, plotWidth),
            _priceToY(segment.end.price, plotHeight)),
        paint,
      );
    }
  }

  /// 通道线端点按时间定位到当前 bars（autoDrawing 基于剔除当日 bar 的序列，
  /// 下标可能与显示序列错位，用时间匹配兜底）
  int? _indexForTime(String time, int fallbackIndex) {
    for (var index = 0; index < bars.length; index++) {
      if (bars[index].time == time) return index;
    }
    return fallbackIndex < bars.length ? fallbackIndex : null;
  }

  void _paintTimeAxis(Canvas canvas, double plotWidth, double plotHeight) {
    final style = _textStyle(AppColors.textFaint, 9);
    final step = math.max(1, (bars.length / 5).round());
    for (var index = 0; index < bars.length; index += step) {
      final time = bars[index].time;
      final label = time.length >= 10 ? time.substring(5, 10) : time;
      _drawText(canvas, label, style,
          Offset(_indexToX(index, plotWidth) - 14, plotHeight + 3));
    }
  }

  void _paintCrosshair(
      Canvas canvas, double plotWidth, double plotHeight, int index) {
    final bar = bars[index];
    final x = _indexToX(index, plotWidth);
    final linePaint = Paint()
      ..color = AppColors.textMuted.withValues(alpha: 0.8)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(x, 0), Offset(x, plotHeight), linePaint);
    if (bar.close != null) {
      final y = _priceToY(bar.close!, plotHeight);
      canvas.drawLine(Offset(0, y), Offset(plotWidth, y), linePaint);
      final label = formatFullPrice(bar.close);
      final painter = TextPainter(
        text: TextSpan(text: label, style: _textStyle(Colors.white, 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      final rect = Rect.fromLTWH(plotWidth + 1, y - painter.height / 2 - 2,
          rightAxisWidth - 2, painter.height + 4);
      canvas.drawRect(rect, Paint()..color = AppColors.axisBorder);
      painter.paint(canvas, Offset(plotWidth + 4, y - painter.height / 2));
    }
  }

  TextStyle _textStyle(Color color, double size) =>
      TextStyle(color: color, fontSize: size);

  void _drawText(Canvas canvas, String text, TextStyle style, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _KlinePainter oldDelegate) {
    return oldDelegate.bars != bars ||
        oldDelegate.autoDrawing != autoDrawing ||
        oldDelegate.lineColors != lineColors ||
        oldDelegate.hoverIndex != hoverIndex ||
        oldDelegate.period != period;
  }
}
