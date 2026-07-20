/// 自动画线（水平位 + 趋势通道），逐函数移植自 frontend/src/utils/autoDrawing.ts。
/// 注意：为保证与网页版行为完全一致，个别看似奇怪的写法（如通道 offset 计算中
/// 使用过滤后数组的下标）也原样保留。
library;

import 'dart:math' as math;

import '../models/models.dart';

const defaultWindow = 90;
const defaultYellow = '#f6d36b';
const _swingRadius = 1;
const _minChannelSpan = 6;
const _recentChannelLookback = 35;

const Map<String, String> defaultLineColors = {
  '0%': defaultYellow,
  '+10%': defaultYellow,
  '+20%': '#f24d4d',
  '+30%': defaultYellow,
  '+40%': defaultYellow,
  '+50%': '#1f6feb',
  '+60%': defaultYellow,
  '+70%': defaultYellow,
  '+80%': '#ffffff',
  '+90%': defaultYellow,
  '+100%': defaultYellow,
};

class AutoLineLevel {
  final String label;
  final int percent;
  final double price;

  const AutoLineLevel({required this.label, required this.percent, required this.price});

  Map<String, Object?> toJson() => {'label': label, 'percent': percent, 'price': price};
}

class AutoPoint {
  final String time;
  final double price;
  final int index;

  const AutoPoint({required this.time, required this.price, required this.index});

  Map<String, Object?> toJson() => {'time': time, 'price': price, 'index': index};
}

class AutoAnchor {
  final String time;
  final double price;
  final String label;

  const AutoAnchor({required this.time, required this.price, required this.label});

  Map<String, Object?> toJson() => {'time': time, 'price': price, 'label': label};
}

enum AutoTrendDirection { up, down, flat }

class AutoTrendSegment {
  final String id;
  final String label;
  final AutoTrendDirection direction;
  final AutoPoint start;
  final AutoPoint end;

  const AutoTrendSegment({
    required this.id,
    required this.label,
    required this.direction,
    required this.start,
    required this.end,
  });

  Map<String, Object?> toJson() => {
        'id': id,
        'label': label,
        'direction': direction.name,
        'start': start.toJson(),
        'end': end.toJson(),
      };
}

class AutoDrawing {
  final AutoTrendDirection direction;
  final int windowSize;
  final KlineBar latest;
  final AutoPoint recentHigh;
  final AutoPoint recentLow;
  final AutoAnchor base;
  final AutoAnchor target;
  final List<AutoLineLevel> levels;
  final List<AutoTrendSegment> trendSegments;
  final AutoLineLevel? nearestLevel;
  final double? nearestDistancePct;

  const AutoDrawing({
    required this.direction,
    required this.windowSize,
    required this.latest,
    required this.recentHigh,
    required this.recentLow,
    required this.base,
    required this.target,
    required this.levels,
    required this.trendSegments,
    required this.nearestLevel,
    required this.nearestDistancePct,
  });

  Map<String, Object?> toJson() => {
        'direction': direction.name,
        'windowSize': windowSize,
        'recentHigh': recentHigh.toJson(),
        'recentLow': recentLow.toJson(),
        'base': base.toJson(),
        'target': target.toJson(),
        'levels': levels.map((level) => level.toJson()).toList(),
        'trendSegments': trendSegments.map((segment) => segment.toJson()).toList(),
        'nearestLevel': nearestLevel?.toJson(),
        'nearestDistancePct': nearestDistancePct,
      };
}

class _Channel {
  final AutoTrendDirection direction;
  final int startIndex;
  final int endIndex;
  final double slope;
  final double intercept;
  final double offset;
  final double score;

  const _Channel({
    required this.direction,
    required this.startIndex,
    required this.endIndex,
    required this.slope,
    required this.intercept,
    required this.offset,
    required this.score,
  });
}

AutoDrawing? computeAutoDrawing(
  List<KlineBar> bars, {
  int windowSize = defaultWindow,
  int levelStep = 10,
  bool extendLevelsBeyond100 = false,
  DateTime? todayUtc,
}) {
  final valid = bars
      .where((bar) => bar.high != null && bar.low != null && bar.close != null)
      .toList();
  if (valid.length < 20) return null;

  final recent =
      valid.length > windowSize ? valid.sublist(valid.length - windowSize) : valid;
  var highIndex = 0;
  var lowIndex = 0;
  for (var index = 0; index < recent.length; index++) {
    if (recent[index].high! > recent[highIndex].high!) highIndex = index;
    if (recent[index].low! < recent[lowIndex].low!) lowIndex = index;
  }

  final highBar = recent[highIndex];
  final lowBar = recent[lowIndex];
  final latest = recent.last;
  final highPrice = highBar.high!;
  final lowPrice = lowBar.low!;
  final close = latest.close!;
  final trendSegments = _buildTrendSegments(recent, todayUtc);
  final direction = trendSegments.isNotEmpty
      ? trendSegments.first.direction
      : (highIndex > lowIndex
          ? AutoTrendDirection.up
          : lowIndex > highIndex
              ? AutoTrendDirection.down
              : AutoTrendDirection.flat);
  final levels = _buildLevels(lowPrice, highPrice, levelStep, extendLevelsBeyond100);
  AutoLineLevel? nearestLevel;
  for (final level in levels) {
    if (nearestLevel == null ||
        (level.price - close).abs() < (nearestLevel.price - close).abs()) {
      nearestLevel = level;
    }
  }

  return AutoDrawing(
    direction: direction,
    windowSize: recent.length,
    latest: latest,
    recentHigh: AutoPoint(time: highBar.time, price: highPrice, index: highIndex),
    recentLow: AutoPoint(time: lowBar.time, price: lowPrice, index: lowIndex),
    base: AutoAnchor(time: lowBar.time, price: lowPrice, label: '$windowSize自然日低点'),
    target: AutoAnchor(time: highBar.time, price: highPrice, label: '$windowSize自然日高点'),
    levels: levels,
    trendSegments: trendSegments,
    nearestLevel: nearestLevel,
    nearestDistancePct: nearestLevel != null && close != 0
        ? _round2((nearestLevel.price - close) / close * 100)
        : null,
  );
}

List<AutoLineLevel> _buildLevels(
    double lowPrice, double highPrice, int levelStep, bool extendLevelsBeyond100) {
  final levels = <AutoLineLevel>[];
  var step = 0;
  final safeStep = math.max(1, levelStep);
  while (extendLevelsBeyond100 || step <= 100) {
    final price = lowPrice * (1 + step / 100);
    if (!extendLevelsBeyond100 && price > highPrice && step > 0) break;
    levels.add(AutoLineLevel(
      label: step == 0 ? '0%' : '+$step%',
      percent: step,
      price: _roundPrice(price),
    ));
    if (extendLevelsBeyond100 && price > highPrice && step > 0) break;
    step += safeStep;
  }
  return levels;
}

List<AutoTrendSegment> _buildTrendSegments(List<KlineBar> bars, DateTime? todayUtc) {
  if (bars.length < 20) return [];
  final completedBars =
      _isCurrentDateBar(bars.last, todayUtc) ? bars.sublist(0, bars.length - 1) : bars;
  if (completedBars.length < 20) return [];
  final result = <AutoTrendSegment>[];
  final channels = _findTrendChannels(completedBars);
  for (var index = 0; index < channels.length; index++) {
    result.addAll(_channelSegments(completedBars, channels[index], index + 1));
  }
  return result;
}

bool _isCurrentDateBar(KlineBar bar, DateTime? todayUtc) {
  if (bar.time.isEmpty) return false;
  final today = (todayUtc ?? DateTime.now().toUtc()).toIso8601String().substring(0, 10);
  final time = bar.time.length >= 10 ? bar.time.substring(0, 10) : bar.time;
  return time == today;
}

List<AutoTrendSegment> _channelSegments(
    List<KlineBar> bars, _Channel channel, int order) {
  final baseStart = _pointOnLine(bars, channel.startIndex, channel.slope, channel.intercept);
  final baseEnd = _pointOnLine(bars, channel.endIndex, channel.slope, channel.intercept);
  final parallelStart = _pointOnLine(
      bars, channel.startIndex, channel.slope, channel.intercept + channel.offset);
  final parallelEnd = _pointOnLine(
      bars, channel.endIndex, channel.slope, channel.intercept + channel.offset);
  if (!_isChannelInPriceRange(bars, [baseStart, baseEnd, parallelStart, parallelEnd])) {
    return [];
  }

  if (channel.direction == AutoTrendDirection.down) {
    return [
      AutoTrendSegment(
        id: 'descending-$order-upper-channel',
        label: '下降通道$order上轨',
        direction: AutoTrendDirection.down,
        start: baseStart,
        end: baseEnd,
      ),
      AutoTrendSegment(
        id: 'descending-$order-lower-channel',
        label: '下降通道$order下轨',
        direction: AutoTrendDirection.down,
        start: parallelStart,
        end: parallelEnd,
      ),
    ];
  }
  return [
    AutoTrendSegment(
      id: 'ascending-$order-lower-channel',
      label: '上升通道$order下轨',
      direction: AutoTrendDirection.up,
      start: baseStart,
      end: baseEnd,
    ),
    AutoTrendSegment(
      id: 'ascending-$order-upper-channel',
      label: '上升通道$order上轨',
      direction: AutoTrendDirection.up,
      start: parallelStart,
      end: parallelEnd,
    ),
  ];
}

bool _isChannelInPriceRange(List<KlineBar> bars, List<AutoPoint> points) {
  final highs = bars.map((bar) => bar.high).whereType<double>().toList();
  final lows =
      bars.map((bar) => bar.low).whereType<double>().where((value) => value > 0).toList();
  if (highs.isEmpty || lows.isEmpty) return false;
  final minLow = lows.reduce(math.min);
  final maxHigh = highs.reduce(math.max);
  final range = [maxHigh - minLow, minLow * 0.1, 0.01].reduce(math.max);
  final minAllowed = math.max(0.01, minLow - range * 1.2);
  final maxAllowed = maxHigh + range * 1.2;
  return points.every((point) =>
      point.price.isFinite &&
      point.price > 0 &&
      point.price >= minAllowed &&
      point.price <= maxAllowed);
}

List<_Channel> _findTrendChannels(List<KlineBar> bars) {
  final latestExtreme = _findLatestExtremeChannel(bars);
  if (latestExtreme != null) return [latestExtreme];

  final swings = _findSwingPivots(bars);
  final ascending = _findAscendingChannel(bars, swings);
  final descending = _findDescendingChannel(bars, swings);
  final candidates = [ascending, descending].whereType<_Channel>().toList()
    ..sort((a, b) {
      final byStart = b.startIndex.compareTo(a.startIndex);
      if (byStart != 0) return byStart;
      return b.score.compareTo(a.score);
    });
  return candidates.isNotEmpty ? [candidates.first] : [];
}

_Channel? _findLatestExtremeChannel(List<KlineBar> bars) {
  final recentStart = math.max(0, bars.length - _recentChannelLookback);
  final channelEnd = bars.length - 1;
  final recentBars = bars.sublist(recentStart);
  final recentLow = _minPivot(recentBars, recentStart, _low);
  final highAfterLow = _maxPivot(bars.sublist(recentLow.index), recentLow.index, _high);
  final recentHigh = _maxPivot(recentBars, recentStart, _high);
  final lowAfterHigh = _minPivot(bars.sublist(recentHigh.index), recentHigh.index, _low);
  final priceRange = recentBars.map((bar) => bar.high ?? double.nan).reduce(math.max) -
      recentBars.map((bar) => bar.low ?? double.nan).reduce(math.min);
  final tolerance = math.max(priceRange * 0.025, 0.01);

  if (recentLow.index < highAfterLow.index && highAfterLow.index >= channelEnd - 1) {
    final latestLow = bars[channelEnd].low;
    if (latestLow != null && latestLow.isFinite && latestLow > recentLow.price) {
      final span = channelEnd - recentLow.index;
      final slope = (latestLow - recentLow.price) / math.max(span, 1);
      if (slope > 0) {
        final intercept = recentLow.price - slope * recentLow.index;
        // 与 TS 版一致：过滤后的数组下标参与 lineValue 计算
        final filtered = <KlineBar>[];
        for (var index = 0; index < recentBars.length; index++) {
          if (recentStart + index >= recentLow.index) filtered.add(recentBars[index]);
        }
        var offset = double.negativeInfinity;
        for (var index = 0; index < filtered.length; index++) {
          final value = (filtered[index].high ?? double.nan) -
              _lineValue(slope, intercept, recentStart + index);
          offset = math.max(offset, value);
        }
        if (offset > tolerance) {
          return _Channel(
            direction: AutoTrendDirection.up,
            startIndex: recentLow.index,
            endIndex: channelEnd,
            slope: slope,
            intercept: intercept,
            offset: offset,
            score: 10000 + highAfterLow.index.toDouble(),
          );
        }
      }
    }
  }

  if (recentHigh.index < lowAfterHigh.index && lowAfterHigh.index >= channelEnd - 1) {
    final latestHigh = bars[channelEnd].high;
    if (latestHigh != null && latestHigh.isFinite && latestHigh < recentHigh.price) {
      final span = channelEnd - recentHigh.index;
      final slope = (latestHigh - recentHigh.price) / math.max(span, 1);
      if (slope < 0) {
        final intercept = recentHigh.price - slope * recentHigh.index;
        final filtered = <KlineBar>[];
        for (var index = 0; index < recentBars.length; index++) {
          if (recentStart + index >= recentHigh.index) filtered.add(recentBars[index]);
        }
        var offset = double.infinity;
        for (var index = 0; index < filtered.length; index++) {
          final value = (filtered[index].low ?? double.nan) -
              _lineValue(slope, intercept, recentStart + index);
          offset = math.min(offset, value);
        }
        if (offset < -tolerance) {
          return _Channel(
            direction: AutoTrendDirection.down,
            startIndex: recentHigh.index,
            endIndex: channelEnd,
            slope: slope,
            intercept: intercept,
            offset: offset,
            score: 10000 + recentLow.index.toDouble(),
          );
        }
      }
    }
  }

  return null;
}

_Channel? _findAscendingChannel(List<KlineBar> bars, _Swings swings) {
  final lows = _ensureEndpointLows(swings.lows, bars);
  if (lows.length < 2 || swings.highs.isEmpty) return null;

  final recentStart = math.max(0, bars.length - _recentChannelLookback);
  final channelEnd = bars.length - 1;
  final recentHigh = _maxPivot(bars.sublist(recentStart), recentStart, _high);
  final recentLow = _minPivot(bars.sublist(recentStart), recentStart, _low);
  final priceRange = bars.map((bar) => bar.high ?? double.nan).reduce(math.max) -
      bars.map((bar) => bar.low ?? double.nan).reduce(math.min);
  final tolerance = math.max(priceRange * 0.025, 0.01);
  _Channel? best;

  for (var start = 0; start < lows.length - 1; start++) {
    for (var end = start + 1; end < lows.length; end++) {
      final first = lows[start];
      final second = lows[end];
      if (first.index < recentStart || second.index < recentStart) continue;
      if (first.index > recentHigh.index || first.index > recentLow.index) continue;
      final span = second.index - first.index;
      if (span < _minChannelSpan) continue;

      final slope = (second.price - first.price) / span;
      if (slope <= 0) continue;

      final intercept = first.price - slope * first.index;
      final lowsInRange = lows
          .where((pivot) => pivot.index >= first.index && pivot.index <= channelEnd)
          .toList();
      final highsInRange = _uniquePivots([...swings.highs, recentHigh])
          .where((pivot) => pivot.index >= first.index && pivot.index <= channelEnd)
          .toList();
      if (highsInRange.isEmpty) continue;

      final lowsAfterLine = lowsInRange
          .where((pivot) =>
              pivot.price >= _lineValue(slope, intercept, pivot.index) - tolerance)
          .length;
      final touches = lowsInRange
          .where((pivot) =>
              (pivot.price - _lineValue(slope, intercept, pivot.index)).abs() <=
              tolerance)
          .length;
      final breaks = lowsInRange.length - lowsAfterLine;
      final offset = highsInRange
          .map((pivot) => pivot.price - _lineValue(slope, intercept, pivot.index))
          .reduce(math.max);
      if (offset <= tolerance) continue;

      final slopeScore = slope / math.max(priceRange, 0.01) * bars.length * 240;
      final recencyScore = second.index * 4 + first.index;
      final fitScore = touches * 45 + lowsAfterLine * 12 - breaks * 120;
      final score = recencyScore + slopeScore + fitScore;
      if (best == null || score > best.score) {
        best = _Channel(
          direction: AutoTrendDirection.up,
          startIndex: first.index,
          endIndex: channelEnd,
          slope: slope,
          intercept: intercept,
          offset: offset,
          score: score,
        );
      }
    }
  }

  return best;
}

_Channel? _findDescendingChannel(List<KlineBar> bars, _Swings swings) {
  final highs = _ensureEndpointHighs(swings.highs, bars);
  if (highs.length < 2 || swings.lows.isEmpty) return null;

  final recentStart = math.max(0, bars.length - _recentChannelLookback);
  final channelEnd = bars.length - 1;
  final recentHigh = _maxPivot(bars.sublist(recentStart), recentStart, _high);
  final recentLow = _minPivot(bars.sublist(recentStart), recentStart, _low);
  final priceRange = bars.map((bar) => bar.high ?? double.nan).reduce(math.max) -
      bars.map((bar) => bar.low ?? double.nan).reduce(math.min);
  final tolerance = math.max(priceRange * 0.025, 0.01);
  _Channel? best;

  for (var start = 0; start < highs.length - 1; start++) {
    for (var end = start + 1; end < highs.length; end++) {
      final first = highs[start];
      final second = highs[end];
      if (first.index < recentStart || second.index < recentStart) continue;
      if (first.index > recentHigh.index || first.index > recentLow.index) continue;
      final span = second.index - first.index;
      if (span < _minChannelSpan) continue;

      final slope = (second.price - first.price) / span;
      if (slope >= 0) continue;

      final intercept = first.price - slope * first.index;
      final highsInRange = highs
          .where((pivot) => pivot.index >= first.index && pivot.index <= channelEnd)
          .toList();
      final lowsInRange = _uniquePivots([...swings.lows, recentLow])
          .where((pivot) => pivot.index >= first.index && pivot.index <= channelEnd)
          .toList();
      if (lowsInRange.isEmpty) continue;

      final highsBelowLine = highsInRange
          .where((pivot) =>
              pivot.price <= _lineValue(slope, intercept, pivot.index) + tolerance)
          .length;
      final touches = highsInRange
          .where((pivot) =>
              (pivot.price - _lineValue(slope, intercept, pivot.index)).abs() <=
              tolerance)
          .length;
      final breaks = highsInRange.length - highsBelowLine;
      final offset = lowsInRange
          .map((pivot) => pivot.price - _lineValue(slope, intercept, pivot.index))
          .reduce(math.min);
      if (offset >= -tolerance) continue;

      final projectedLatest = _lineValue(slope, intercept, channelEnd);
      final latestHigh = bars[channelEnd].high ?? double.nan;
      if (latestHigh > projectedLatest + tolerance) continue;
      final latestDistance = math.max(projectedLatest - latestHigh, 0).toDouble();
      final slopeScore = slope.abs() / math.max(priceRange, 0.01) * bars.length * 240;
      final recencyScore = second.index * 4 + first.index;
      final fitScore =
          touches * 45 + highsBelowLine * 12 - breaks * 120 - latestDistance * 4;
      final score = recencyScore + slopeScore + fitScore;
      if (best == null || score > best.score) {
        best = _Channel(
          direction: AutoTrendDirection.down,
          startIndex: first.index,
          endIndex: channelEnd,
          slope: slope,
          intercept: intercept,
          offset: offset,
          score: score,
        );
      }
    }
  }

  return best;
}

class _Swings {
  final List<AutoPoint> lows;
  final List<AutoPoint> highs;

  const _Swings({required this.lows, required this.highs});
}

_Swings _findSwingPivots(List<KlineBar> bars) {
  final lows = <AutoPoint>[];
  final highs = <AutoPoint>[];

  for (var index = _swingRadius; index < bars.length - _swingRadius; index++) {
    final window = bars.sublist(index - _swingRadius, index + _swingRadius + 1);
    final low = bars[index].low ?? double.nan;
    final high = bars[index].high ?? double.nan;
    if (window.every((bar) => low <= (bar.low ?? double.nan))) {
      lows.add(_pivotFromBar(bars[index], index, _low));
    }
    if (window.every((bar) => high >= (bar.high ?? double.nan))) {
      highs.add(_pivotFromBar(bars[index], index, _high));
    }
  }

  return _Swings(lows: lows, highs: highs);
}

List<AutoPoint> _ensureEndpointLows(List<AutoPoint> lows, List<KlineBar> bars) {
  final midpoint = bars.length ~/ 2;
  final finalStart = math.max(0, bars.length - 12);
  final firstLow = _minPivot(bars.sublist(0, midpoint + 1), 0, _low);
  final secondLow = _minPivot(bars.sublist(midpoint), midpoint, _low);
  final finalLow = _minPivot(bars.sublist(finalStart), finalStart, _low);
  return _uniquePivots([...lows, firstLow, secondLow, finalLow]);
}

List<AutoPoint> _ensureEndpointHighs(List<AutoPoint> highs, List<KlineBar> bars) {
  final midpoint = bars.length ~/ 2;
  final finalStart = math.max(0, bars.length - 12);
  final firstHigh = _maxPivot(bars.sublist(0, midpoint + 1), 0, _high);
  final secondHigh = _maxPivot(bars.sublist(midpoint), midpoint, _high);
  final finalHigh = _maxPivot(bars.sublist(finalStart), finalStart, _high);
  return _uniquePivots([...highs, firstHigh, secondHigh, finalHigh]);
}

List<AutoPoint> _uniquePivots(List<AutoPoint> pivots) {
  final byIndex = <int, AutoPoint>{};
  for (final pivot in pivots) {
    byIndex[pivot.index] = pivot;
  }
  return byIndex.values.toList()..sort((a, b) => a.index.compareTo(b.index));
}

double? Function(KlineBar bar) get _high => (bar) => bar.high;
double? Function(KlineBar bar) get _low => (bar) => bar.low;

AutoPoint _maxPivot(
    List<KlineBar> bars, int offset, double? Function(KlineBar) kind) {
  var selectedIndex = 0;
  for (var index = 0; index < bars.length; index++) {
    if ((kind(bars[index]) ?? double.nan) >
        (kind(bars[selectedIndex]) ?? double.nan)) {
      selectedIndex = index;
    }
  }
  return _pivotFromBar(bars[selectedIndex], offset + selectedIndex, kind);
}

AutoPoint _minPivot(
    List<KlineBar> bars, int offset, double? Function(KlineBar) kind) {
  var selectedIndex = 0;
  for (var index = 0; index < bars.length; index++) {
    if ((kind(bars[index]) ?? double.nan) <
        (kind(bars[selectedIndex]) ?? double.nan)) {
      selectedIndex = index;
    }
  }
  return _pivotFromBar(bars[selectedIndex], offset + selectedIndex, kind);
}

AutoPoint _pointOnLine(List<KlineBar> bars, int index, double slope, double intercept) {
  return AutoPoint(
    time: bars[index].time,
    price: _roundPrice(_lineValue(slope, intercept, index)),
    index: index,
  );
}

double _lineValue(double slope, double intercept, int index) =>
    slope * index + intercept;

AutoPoint _pivotFromBar(KlineBar bar, int index, double? Function(KlineBar) kind) {
  return AutoPoint(time: bar.time, price: kind(bar) ?? double.nan, index: index);
}

double _roundPrice(double value) {
  final factor = value >= 100 ? 100 : 1000;
  return (value * factor).roundToDouble() / factor;
}

double _round2(double value) => (value * 100).roundToDouble() / 100;

String trendLabel(AutoTrendDirection direction) {
  switch (direction) {
    case AutoTrendDirection.up:
      return '向上趋势';
    case AutoTrendDirection.down:
      return '向下趋势';
    case AutoTrendDirection.flat:
      return '震荡观察';
  }
}

String colorForLevel(AutoLineLevel level, Map<String, String> colors) {
  if (level.label == '+20%') return '#f24d4d';
  if (level.label == '+50%') return '#1f6feb';
  if (level.label == '+80%') return '#ffffff';
  return colors[level.label] ?? defaultLineColors[level.label] ?? defaultYellow;
}
