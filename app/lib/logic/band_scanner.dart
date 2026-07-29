/// 八档局核心筛选逻辑（纯函数），逐条移植自 backend/app/scanner.py。
/// 90 日波段（低点→现在）分档：第 k 档 = 波段内先过 (阈值-10)%，
/// 现价至少过阈值%，阈值 = 20+30*(k-1)。
library;

import 'dart:math' as math;

import '../models/models.dart';

/// 相邻两档间隔
const groupStep = 30.0;

/// 第 k 档“最后一天至少过”阈值 = 20 + 30*(k-1)
const groupFinalBase = 20.0;

/// “先过”线 = 阈值 - 10（第一档先过10%、第二档先过40%…）
const groupPreOffset = 10.0;

const maxGroups = 8;
const scanWindowDays = 90;
const scanMinBars = 20;

/// 按最新涨幅归档：第 k 档有效区间 [主线+10, 主线+20)，主线 = 20+30(k-1)。
/// 即一档[30,40)、二档[60,70)、三档[90,100)…（“在20%~40%之间且大于30%”的推广）。
/// 刚过主线不足10个点（如[20,30)）与下一档过渡区（如[40,50)）都不入档；超250%不入档。
int? classifyGroup(double? pct) {
  if (pct == null || pct < groupFinalBase) return null;
  final k = ((pct - groupFinalBase) / groupStep).floor() + 1;
  if (k > maxGroups) return null;
  final offset = pct - groupThreshold(k);
  if (offset < groupPreOffset) return null; // 过了主线但没高出10个点（振江 25% 场景）
  if (offset >= groupStep - groupPreOffset) {
    return null; // 过了下一档先过线（主线+20）→ 过渡区（600617 47% 场景）
  }
  return k;
}

double groupThreshold(int group) => groupFinalBase + groupStep * (group - 1);

/// 第 k 档的先过线：10/40/70/100/…
double preLine(int group) => groupThreshold(group) - groupPreOffset;

/// 从顶部下来判定：波段最高点(maxPct)曾站上的最高档位线（先过线 10/40/70/…
/// 与主线 20/50/80/… 都算），现价已跌破 → 排除。
bool isFallingFromTop(double pct, double maxPct) {
  double? highestCrossed;
  for (var j = 1; j <= maxGroups + 1; j++) {
    // 允许越过第八档之上的线
    for (final line in [preLine(j), groupThreshold(j)]) {
      if (maxPct >= line) highestCrossed = line;
    }
  }
  if (highestCrossed == null) return false;
  return pct < highestCrossed;
}

/// 主板涨停判定：现价（收盘后即收盘价）等于 round(昨收×1.1, 2)。
/// ST 已被排除，不考虑 5% 档。
bool isLimitUp(double? price, double? preClose, {double ratio = 1.1}) {
  if (price == null || preClose == null || preClose <= 0) return false;
  final limit = (preClose * ratio * 100).roundToDouble() / 100;
  return (price - limit).abs() < 0.001;
}

/// 仅沪深主板（60/00），排除名称含 ST
bool eligibleSymbol(String symbol, String name) {
  final clean = symbol.trim();
  if (!clean.startsWith('60') && !clean.startsWith('00')) return false;
  if (name.toUpperCase().contains('ST')) return false;
  return true;
}

DateTime? _barDate(KlineBar bar) {
  final raw = bar.time.length >= 10 ? bar.time.substring(0, 10) : bar.time;
  return DateTime.tryParse('${raw}T00:00:00');
}

/// 剔除周末与 OHLC 缺失的 bar
List<KlineBar> validScanBars(List<KlineBar> bars) {
  final result = <KlineBar>[];
  for (final bar in bars) {
    final day = _barDate(bar);
    if (day == null ||
        day.weekday == DateTime.saturday ||
        day.weekday == DateTime.sunday) {
      continue;
    }
    if (!bar.hasOhlc) continue;
    result.add(bar);
  }
  return result;
}

/// 近 days 自然日窗口（以最后一根 bar 日期为基准）
List<KlineBar> sliceScanWindow(List<KlineBar> bars, {int days = scanWindowDays}) {
  final valid = validScanBars(bars);
  if (valid.isEmpty) return [];
  final latest = _barDate(valid.last)!;
  final cutoff = latest.subtract(Duration(days: days));
  return valid.where((bar) => !_barDate(bar)!.isBefore(cutoff)).toList();
}

class BandHit {
  final String symbol;
  final String name;
  final double price;
  final double low90;
  final double pct;
  final int group;
  final double threshold;
  final double over;
  final double maxPct;
  final String lowDate;
  final String crossDate;
  final bool limitUp;

  const BandHit({
    required this.symbol,
    required this.name,
    required this.price,
    required this.low90,
    required this.pct,
    required this.group,
    required this.threshold,
    required this.over,
    required this.maxPct,
    required this.lowDate,
    required this.crossDate,
    this.limitUp = false,
  });

  BandHit copyWith({bool? limitUp}) => BandHit(
        symbol: symbol,
        name: name,
        price: price,
        low90: low90,
        pct: pct,
        group: group,
        threshold: threshold,
        over: over,
        maxPct: maxPct,
        lowDate: lowDate,
        crossDate: crossDate,
        limitUp: limitUp ?? this.limitUp,
      );

  Map<String, Object?> toJson() => {
        'symbol': symbol,
        'name': name,
        'price': price,
        'low90': low90,
        'pct': pct,
        'group': group,
        'threshold': threshold,
        'over': over,
        'max_pct': maxPct,
        'low_date': lowDate,
        'cross_date': crossDate,
        'limit_up': limitUp,
      };

  factory BandHit.fromJson(Map<String, Object?> json) => BandHit(
        symbol: json['symbol'] as String,
        name: (json['name'] as String?) ?? '',
        price: (json['price'] as num).toDouble(),
        low90: (json['low90'] as num).toDouble(),
        pct: (json['pct'] as num).toDouble(),
        group: (json['group'] as num).toInt(),
        threshold: (json['threshold'] as num).toDouble(),
        over: (json['over'] as num).toDouble(),
        maxPct: (json['max_pct'] as num).toDouble(),
        lowDate: (json['low_date'] as String?) ?? '',
        crossDate: (json['cross_date'] as String?) ?? '',
        limitUp: (json['limit_up'] as bool?) ?? false,
      );
}

double _roundTo(double value, int digits) {
  final factor = math.pow(10, digits).toDouble();
  return (value * factor).roundToDouble() / factor;
}

/// 对齐 scanner.py::evaluate_stock。命中返回 BandHit（limitUp 由调用方补），
/// 不命中返回 null。
BandHit? evaluateStock(
  String symbol,
  String name,
  double? price,
  List<KlineBar> bars, {
  DateTime? today,
}) {
  if (price == null) return null;
  final now = today ?? DateTime.now();
  final valid = validScanBars(bars);
  if (valid.length < scanMinBars) return null;
  final firstDay = _barDate(valid.first)!;
  // 上市不足 90 天（最早日线晚于今日-90天）不选
  if (firstDay.isAfter(now.subtract(const Duration(days: scanWindowDays)))) {
    return null;
  }
  final window = sliceScanWindow(valid);
  if (window.isEmpty) return null;

  var lowIndex = 0;
  for (var i = 1; i < window.length; i++) {
    if (window[i].low! < window[lowIndex].low!) lowIndex = i;
  }
  final low90 = window[lowIndex].low!;
  if (low90 <= 0) return null;
  if (lowIndex >= window.length - 1) {
    return null; // 低点就是最后一天，没有“低点→高点”的波段
  }

  final pct = (price / low90 - 1) * 100;
  final group = classifyGroup(pct);
  if (group == null) return null;

  var maxPct = pct;
  for (final bar in window.sublist(lowIndex)) {
    final close = bar.close;
    if (close == null) continue;
    maxPct = math.max(maxPct, (close / low90 - 1) * 100);
  }
  if (isFallingFromTop(pct, maxPct)) {
    return null; // 从顶部下来（跌破曾站上的先过线）的不要
  }

  double? beforeHigh;
  for (final bar in window.sublist(0, lowIndex)) {
    final close = bar.close;
    if (close == null) continue;
    beforeHigh = beforeHigh == null ? close : math.max(beforeHigh, close);
  }
  if (beforeHigh != null) {
    final beforeHighPct = (beforeHigh / low90 - 1) * 100;
    if (beforeHighPct >= pct) {
      return null; // 90日内先下降到底部再反弹、且未超过下跌起点 → V型反弹不要
    }
  }

  final threshold = groupThreshold(group);
  final preLevel = low90 * (1 + (threshold - groupPreOffset) / 100);

  String? crossDate;
  for (final bar in window.sublist(lowIndex + 1)) {
    final close = bar.close;
    if (close != null && close >= preLevel) {
      crossDate = bar.time.substring(0, math.min(10, bar.time.length));
      break;
    }
  }
  crossDate ??= window.last.time
      .substring(0, math.min(10, window.last.time.length)); // 只有今日盘中价过线

  return BandHit(
    symbol: symbol,
    name: name,
    price: price,
    low90: _roundTo(low90, 3),
    pct: _roundTo(pct, 2),
    group: group,
    threshold: threshold,
    over: _roundTo(pct - threshold, 2),
    maxPct: _roundTo(maxPct, 2),
    lowDate: window[lowIndex]
        .time
        .substring(0, math.min(10, window[lowIndex].time.length)),
    crossDate: crossDate,
  );
}
