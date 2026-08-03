/// 八档局核心筛选逻辑（纯函数），逐条移植自 backend/app/scanner.py。
/// 90 日波段（低点→现在）分档：一档须站上30确认[30,40)，40是奇点；
/// 二档及以上过主线即入（[50,70)、[80,100)…）。低点不区分反转/起点。
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

/// 按最新涨幅归档。一档须站上30确认：[30,40)；40是奇点，[40,50)不入档；
/// 二档及以上过主线即入：[50,70)、[80,100)、[110,130)…（上沿 = 下一主线−10 的奇点）；
/// 过渡区（70~80/100~110/…）与超250%不入档。
int? classifyGroup(double? pct) {
  if (pct == null || pct < groupFinalBase + groupPreOffset) {
    return null; // <30：过20未站上30只是“站稳20”，不入档
  }
  if (pct < 40) return 1;
  if (pct < 50) return null; // 40是奇点：过了40、还没站上50（利欧 41.7% 场景）
  final k = ((pct - groupFinalBase) / groupStep).floor() + 1;
  if (k > maxGroups) return null;
  final offset = pct - groupThreshold(k);
  if (offset >= groupStep - groupPreOffset) {
    return null; // 到达下一奇点（主线+20）→ 过渡区
  }
  return k;
}

/// 入档线：一档需站上30确认，二档及以上过主线即入。
double groupEntryLine(int group) =>
    group == 1 ? groupFinalBase + groupPreOffset : groupThreshold(group);

double groupThreshold(int group) => groupFinalBase + groupStep * (group - 1);

/// 跌破曾站上的最高主线（20/50/80/…）→ 打标记；重新站回主线上方即恢复。
bool isFallingFromTop(double pct, double maxPct, [double? maxHighPct]) {
  // 异常回落（收回后自动恢复）：
  // 1) 收盘曾站上的最高主线（20/50/80/…），现价跌破；
  // 2) 盘中曾冲过某奇点（40/70/100/…，用最高价判"冲高"），现价低于 奇点−10（30/60/90/…）。
  final high = maxHighPct ?? maxPct;
  double? floor;
  for (var j = 1; j <= maxGroups; j++) {
    final main = groupThreshold(j);
    final singular = main + groupStep - groupPreOffset; // 40/70/100/…
    if (maxPct >= main) {
      floor = floor == null ? main : math.max(floor, main);
    }
    if (high >= singular) {
      final level = singular - groupPreOffset; // 30/60/90/…
      floor = floor == null ? level : math.max(floor, level);
    }
  }
  if (floor == null) return false;
  return pct < floor;
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

  /// 跌破主线：波段峰值曾站上某条主线（20/50/80/…），现价已跌破
  final bool fromTop;

  /// 近一年有分红（含已公告未除息的今年分红），基本面阶段补标
  final bool dividendRecent;

  /// 最新报告期归母净利润≥0，基本面阶段补标
  final bool profitOk;

  /// 估市值：最新报告期营收年化×10 > 总市值，基本面阶段补标
  final bool revenueOk;

  /// 日/周/月三周期 LON 与 LONMA 都向上且 LON≥LONMA，lon 阶段补标
  final bool lonOk;

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
    this.fromTop = false,
    this.dividendRecent = false,
    this.profitOk = false,
    this.revenueOk = false,
    this.lonOk = false,
  });

  BandHit copyWith({
    bool? limitUp,
    bool? dividendRecent,
    bool? profitOk,
    bool? revenueOk,
    bool? lonOk,
  }) =>
      BandHit(
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
        fromTop: fromTop,
        dividendRecent: dividendRecent ?? this.dividendRecent,
        profitOk: profitOk ?? this.profitOk,
        revenueOk: revenueOk ?? this.revenueOk,
        lonOk: lonOk ?? this.lonOk,
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
        'from_top': fromTop,
        'dividend_recent': dividendRecent,
        'profit_ok': profitOk,
        'revenue_ok': revenueOk,
        'lon_ok': lonOk,
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
        fromTop: (json['from_top'] as bool?) ?? false,
        // 旧持久化数据缺基本面/技术面标记字段，默认 false
        dividendRecent: (json['dividend_recent'] as bool?) ?? false,
        profitOk: (json['profit_ok'] as bool?) ?? false,
        revenueOk: (json['revenue_ok'] as bool?) ?? false,
        lonOk: (json['lon_ok'] as bool?) ?? false,
      );
}

double _roundTo(double value, int digits) {
  final factor = math.pow(10, digits).toDouble();
  return (value * factor).roundToDouble() / factor;
}

/// 对齐 scanner.py::evaluate_stock。命中返回 BandHit（limitUp 由调用方补），
/// 不命中返回 null。跌破曾站上主线（fromTop）只打标记不丢弃，
/// 由展示层筛选开关决定是否显示。
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
  var maxHighPct = pct;
  for (final bar in window.sublist(lowIndex)) {
    final close = bar.close;
    if (close != null) maxPct = math.max(maxPct, (close / low90 - 1) * 100);
    final high = bar.high;
    if (high != null) maxHighPct = math.max(maxHighPct, (high / low90 - 1) * 100);
  }
  // 异常回落只打标记，由展示层筛选开关决定是否显示（收回后自动恢复）
  final fromTop = isFallingFromTop(pct, maxPct, maxHighPct);

  final threshold = groupThreshold(group);
  final entryLevel = low90 * (1 + groupEntryLine(group) / 100);

  String? crossDate;
  for (final bar in window.sublist(lowIndex + 1)) {
    final close = bar.close;
    if (close != null && close >= entryLevel) {
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
    fromTop: fromTop,
  );
}
