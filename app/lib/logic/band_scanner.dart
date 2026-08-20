/// 八档局核心筛选逻辑（纯函数），逐条移植自 backend/app/scanner.py。
/// 90 日波段（低点→现在）按档位下沿 20/40/70/100/130/160/190/220 分档，
/// 每档区间 [本档下沿, 下一档下沿)。低点不区分反转/起点。
library;

import 'dart:math' as math;

import '../models/models.dart';

/// 八档下沿（入档线）：分界线 = K线主线(20/50/80/110…) − 10，
/// 一档 20 除外（对齐 scanner.py::GROUP_LOWER）
const groupLower = <double>[20, 40, 70, 100, 130, 160, 190, 220];

/// 破势用的 K线主线（与档位分界是两套口径：档位=主线−10）。
/// 对齐 backend/app/breakout.py::MAIN_LINES
const breakoutMainLines = <double>[20, 50, 80, 110, 140, 170, 200, 230];

const maxGroups = 8;
const scanWindowDays = 90;
const scanMinBars = 20;

/// 一路北上允许的最大回撤（收盘口径）
const northMaxDrawdown = 0.30;

/// 按最新收盘涨幅归档，档位分界 20/40/70/100/130/160/190/220：
/// 一档 [20,40)、二档 [40,70)、三档 [70,100)、四档 [100,130)、五档 [130,160)、
/// 六档 [160,190)、七档 [190,220)、八档 [220,∞)。
/// 过 40% 即从一档升为二档（"快到下一条主线"就升档）；八档没有上限。
int? classifyGroup(double? pct) {
  if (pct == null || pct < groupLower[0]) return null;
  var group = 1;
  for (var index = 0; index < groupLower.length; index++) {
    if (pct >= groupLower[index]) group = index + 1;
  }
  return group;
}

/// 档位下沿（入档线）
double groupThreshold(int group) =>
    groupLower[(group < 1 ? 1 : (group > maxGroups ? maxGroups : group)) - 1];

/// 回落判定：历史收盘最高档高于当前档 → 是从更高档掉下来的，不算当前档。
/// 例：冲到 45%（二档）后回落到 35%（一档区间）→ true，
/// 要重新站上 40% 才以二档出现（对齐 scanner.py::is_falling_back）。
bool isFallingBack(double? pct, double? maxPct) {
  final current = classifyGroup(pct);
  final peak = classifyGroup(maxPct);
  if (current == null || peak == null) return false;
  return peak > current;
}

/// 一路北上：从低到高——最高点在波段低点之后，且低点之后收盘口径最大回撤 ≤30%。
/// 破势分组：已突破的最高主线序号（1=站上20、2=站上50、3=站上80…），
/// 未过 20 返回 null。每只股只归最高一组，不重复计入前面几组。
/// 对齐 backend/app/breakout.py::breakout_stage
int? breakoutStage(double? pct) {
  if (pct == null || pct < breakoutMainLines[0]) return null;
  var stage = 1;
  for (var index = 0; index < breakoutMainLines.length; index++) {
    if (pct >= breakoutMainLines[index]) stage = index + 1;
  }
  return stage;
}

/// 分组标签：2 → "20→50"、3 → "50→80"…
String breakoutStageLabel(int stage) {
  if (stage <= 1) return '0→${breakoutMainLines[0].toInt()}';
  final capped = stage.clamp(1, breakoutMainLines.length);
  return '${breakoutMainLines[capped - 2].toInt()}→'
      '${breakoutMainLines[capped - 1].toInt()}';
}

/// 蓄势待发的"刚过线"阈值：站上主线后超出不超过这么多个百分点
const buildupMaxOver = 5.0;

/// 蓄势待发：刚刚站上某条主线、还没走远。
/// 返回超出该主线几个百分点（0 ≤ over ≤ [buildupMaxOver]）；
/// 走太远、或还没过 20% 都返回 null。
/// 例：52% → 刚过 50 线（超出 2）；58% → null（超出 8，已经走远了）。
double? buildupOver(double? pct, {double maxOver = buildupMaxOver}) {
  final line = _crossedLine(pct);
  if (line == null) return null;
  final over = _roundTo(pct! - line, 2);
  return over <= maxOver ? over : null;
}

/// 蓄势待发刚站上的那条主线；不满足条件返回 null
double? buildupLine(double? pct, {double maxOver = buildupMaxOver}) =>
    buildupOver(pct, maxOver: maxOver) == null ? null : _crossedLine(pct);

/// 已站上的最高主线（没过 20% 返回 null）
double? _crossedLine(double? pct) {
  if (pct == null || pct < breakoutMainLines[0]) return null;
  double? line;
  for (final value in breakoutMainLines) {
    if (pct >= value) line = value;
  }
  return line;
}

/// 零帧起手：现价离 90 日低点不超过这么多个百分点（"停留在 0 点"）
const zeroBaseMaxPct = 3.0;

/// 零帧起手：低点之前的高点至少要有这么高（"从高处下来"，不是一路阴跌的平地）
const zeroBaseMinPeak = 50.0;

bool isNorthBound(List<KlineBar> window, int lowIndex,
    {double maxDrawdown = northMaxDrawdown}) {
  final n = window.length;
  if (n < 3) return false;
  var highIndex = 0;
  for (var i = 1; i < n; i++) {
    final h = window[i].high;
    if (h != null &&
        (window[highIndex].high == null || h > window[highIndex].high!)) {
      highIndex = i;
    }
  }
  if (highIndex <= lowIndex) return false;
  // 低点之后的震荡回落（收盘口径最大回撤）不能超过 maxDrawdown
  double? peak;
  for (final bar in window.sublist(lowIndex)) {
    final close = bar.close;
    if (close == null) continue;
    if (peak == null || close > peak) {
      peak = close;
    } else if (peak > 0 && (peak - close) / peak > maxDrawdown) {
      return false;
    }
  }
  return true;
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

/// 换手率筛选阈值（%），开关“换手>3%”
const turnoverFilterMin = 3.0;

/// 近 3 日涨幅筛选阈值（%），开关“3日>7%”
const chg3FilterMin = 7.0;

/// 近 5 日涨幅筛选阈值（%），开关“5日>14%”
const chg5FilterMin = 14.0;

/// 90 日波动筛选阈值（%），开关“波动≥40%”：
/// 低点之后收盘最高涨幅（maxPct）不到这个数的，说明这 90 天从 0% 起就没
/// 真正动过，去掉。只影响一档里那批（二档起 pct 本身就 ≥40）。
const swingFilterMin = 40.0;

/// 近 [days] 日涨幅%（对齐 backend/app/scanner.py 的 chg3/chg5）：
/// 基准取本地日 K 窗口的收盘序列——窗口最后一根就是今天则取
/// closes[-(days+1)]（今天那根是“现在”，不能当基准），否则取 closes[-days]；
/// 涨幅 = (现价/基准 − 1)×100。数据不足/基准非正返回 null（= 未知）。
double? changeOverDays(
  List<KlineBar> bars,
  double? price,
  int days, {
  required DateTime today,
}) {
  if (price == null || price <= 0 || days < 1) return null;
  final closes = <double>[];
  var lastTime = '';
  for (final bar in bars) {
    final close = bar.close;
    if (close == null) continue;
    closes.add(close);
    lastTime = bar.time;
  }
  if (closes.isEmpty) return null;
  final lastDay = lastTime.length >= 10 ? lastTime.substring(0, 10) : lastTime;
  final todayText = today.toIso8601String().substring(0, 10);
  final back = lastDay == todayText ? days + 1 : days;
  final index = closes.length - back;
  if (index < 0) return null;
  final base = closes[index];
  if (base <= 0) return null;
  return (price / base - 1) * 100;
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

  /// 回落：历史收盘最高档高于当前档（曾进过更高档、现已回落），
  /// 重新站上该档下沿即恢复
  final bool fromTop;

  /// 一路北上：90日整体向上，低点在窗口前1/3、最高点在后1/3
  final bool northOk;

  /// 当日换手率%（来自扫描快照 Quote.turnover），行情源没给则 null
  final double? turnover;

  /// 近 3 日涨幅%（本地日 K 算），数据不足则 null
  final double? chg3;

  /// 近 5 日涨幅%（本地日 K 算），数据不足则 null
  final double? chg5;

  /// 总市值（亿元，来自扫描快照）。补充数据时估市值判定要用它，
  /// 所以随命中一起持久化。
  final double? marketCap;

  /// 近一年有分红（含已公告未除息的今年分红）。
  /// **三态**：true/false = 已确定，null = 缓存里没有、尚未补充。
  final bool? dividendRecent;

  /// 最新报告期归母净利润≥0。三态，null = 未补充
  final bool? profitOk;

  /// 估市值：最新报告期营收年化×10 > 总市值。三态，null = 未补充
  final bool? revenueOk;

  /// 估市值倍数（年化营收×10 ÷ 总市值）；null = 未补充/数据缺失
  final double? revenueRatio;

  /// 破势分组：已突破的最高主线序号（2=「20→50」组、3=「50→80」…）
  final int? breakStage;

  /// 日/周/月三周期 LON 与 LONMA 都向上且 LON≥LONMA。三态，null = 未补充
  final bool? lonOk;

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
    this.turnover,
    this.chg3,
    this.chg5,
    this.marketCap,
    this.dividendRecent,
    this.profitOk,
    this.revenueOk,
    this.revenueRatio,
    this.breakStage,
    this.lonOk,
    this.northOk = false,
  });

  /// 基本面三个标记来自同一条缓存，要么都有要么都没有
  bool get fundamentalsKnown => dividendRecent != null;

  bool get lonKnown => lonOk != null;

  /// 基本面与 LON 标记都已确定（false 时“补充数据”按钮会带上它）
  bool get marksKnown => fundamentalsKnown && lonKnown;

  BandHit copyWith({
    bool? limitUp,
    double? turnover,
    double? marketCap,
    bool? dividendRecent,
    bool? profitOk,
    bool? revenueOk,
    double? revenueRatio,
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
        turnover: turnover ?? this.turnover,
        chg3: chg3,
        chg5: chg5,
        marketCap: marketCap ?? this.marketCap,
        dividendRecent: dividendRecent ?? this.dividendRecent,
        profitOk: profitOk ?? this.profitOk,
        revenueOk: revenueOk ?? this.revenueOk,
        revenueRatio: revenueRatio ?? this.revenueRatio,
        breakStage: breakStage,
        lonOk: lonOk ?? this.lonOk,
        northOk: northOk,
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
        'turnover': turnover,
        'chg3': chg3,
        'chg5': chg5,
        'market_cap': marketCap,
        'dividend_recent': dividendRecent,
        'profit_ok': profitOk,
        'revenue_ok': revenueOk,
        'revenue_ratio': revenueRatio,
        'break_stage': breakStage,
        'lon_ok': lonOk,
        'north_ok': northOk,
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
        turnover: (json['turnover'] as num?)?.toDouble(),
        chg3: (json['chg3'] as num?)?.toDouble(),
        chg5: (json['chg5'] as num?)?.toDouble(),
        marketCap: (json['market_cap'] as num?)?.toDouble(),
        // 标记缺字段 = 未知（不是 false）：等用户点「补充数据」再确定
        dividendRecent: json['dividend_recent'] as bool?,
        profitOk: json['profit_ok'] as bool?,
        revenueOk: json['revenue_ok'] as bool?,
        revenueRatio: (json['revenue_ratio'] as num?)?.toDouble(),
        breakStage: (json['break_stage'] as num?)?.toInt(),
        lonOk: json['lon_ok'] as bool?,
        northOk: (json['north_ok'] as bool?) ?? false,
      );
}

double _roundTo(double value, int digits) {
  final factor = math.pow(10, digits).toDouble();
  return (value * factor).roundToDouble() / factor;
}

/// 对齐 scanner.py::evaluate_stock。90 日波段（低点→现在）按档位下沿
/// 20/40/70/100/130/160/190/220 分档，每档区间 [本档下沿, 下一档下沿)。
/// 命中返回 BandHit（limitUp 由调用方补），不命中返回 null。
/// 回落（fromTop：历史最高档高于当前档）只打标记不丢弃，
/// 由展示层筛选开关决定是否显示（重新站上该档下沿即自动恢复）。
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
    if (close != null) maxPct = math.max(maxPct, (close / low90 - 1) * 100);
  }
  // 回落只打标记，由展示层筛选开关决定是否显示（重新站上该档下沿即恢复）
  final fromTop = isFallingBack(pct, maxPct);
  final northOk = isNorthBound(window, lowIndex);

  final threshold = groupThreshold(group);
  // 入档线就是本档下沿（一档 20%、二档 40%、三档 70%…）
  final entryLevel = low90 * (1 + threshold / 100);

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

  final chg3 = changeOverDays(window, price, 3, today: now);
  final chg5 = changeOverDays(window, price, 5, today: now);

  return BandHit(
    symbol: symbol,
    name: name,
    price: price,
    chg3: chg3 == null ? null : _roundTo(chg3, 2),
    chg5: chg5 == null ? null : _roundTo(chg5, 2),
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
    northOk: northOk,
    breakStage: breakoutStage(pct),
  );
}

/// 零帧起手：90 日窗口里先在高处、随后一路下来，现在贴着 90 日低点。
///
/// 与 [evaluateStock] 是两套互斥的口径——八档局只收 pct ≥ 20% 的（站在半山腰
/// 往上），这里要的正是被它筛掉的那批：pct ≈ 0，趴在地板上。
/// 判定三条：
///   1. 高点在低点**之前**（先高后低，是"下来"不是"起来"）；
///   2. 该高点相对低点涨幅 ≥ [zeroBaseMinPeak]（至少从 +50% 处摔下来）；
///   3. 现价相对低点 ≤ [zeroBaseMaxPct]（最终停在 0 点，没反弹走）。
/// 命中返回 group=0 的 BandHit（threshold/over 均为 0，破势单独一组用）；
/// [crossDate] 复用为**高点日期**，卡片按 group==0 换一套标签显示。
BandHit? evaluateZeroBase(
  String symbol,
  String name,
  double? price,
  List<KlineBar> bars, {
  DateTime? today,
  double maxPct = zeroBaseMaxPct,
  double minPeak = zeroBaseMinPeak,
}) {
  if (price == null) return null;
  final now = today ?? DateTime.now();
  final valid = validScanBars(bars);
  if (valid.length < scanMinBars) return null;
  final firstDay = _barDate(valid.first)!;
  if (firstDay.isAfter(now.subtract(const Duration(days: scanWindowDays)))) {
    return null; // 上市不足 90 天
  }
  final window = sliceScanWindow(valid);
  if (window.isEmpty) return null;

  var lowIndex = 0;
  for (var i = 1; i < window.length; i++) {
    if (window[i].low! < window[lowIndex].low!) lowIndex = i;
  }
  final low90 = window[lowIndex].low!;
  if (low90 <= 0) return null;
  if (lowIndex == 0) return null; // 低点在最左边，高点无从谈起

  // 高点只看低点**之前**那段：先高后低才是"从高处下降到 0 点"
  var peakIndex = 0;
  for (var i = 1; i <= lowIndex; i++) {
    final close = window[i].close;
    if (close != null &&
        (window[peakIndex].close == null || close > window[peakIndex].close!)) {
      peakIndex = i;
    }
  }
  final peakClose = window[peakIndex].close;
  if (peakClose == null) return null;
  final peakPct = (peakClose / low90 - 1) * 100;
  if (peakPct < minPeak) return null;

  final pct = (price / low90 - 1) * 100;
  if (pct > maxPct) return null; // 已经反弹走了，不算"停留在 0 点"

  return BandHit(
    symbol: symbol,
    name: name,
    price: price,
    low90: _roundTo(low90, 3),
    pct: _roundTo(pct, 2),
    group: 0, // 0 = 零帧起手，不属于八档任何一档
    threshold: 0,
    over: 0,
    maxPct: _roundTo(peakPct, 2),
    lowDate: window[lowIndex]
        .time
        .substring(0, math.min(10, window[lowIndex].time.length)),
    // 这一组没有"过线"，位置复用成高点日期（卡片按 group==0 换标签）
    crossDate: window[peakIndex]
        .time
        .substring(0, math.min(10, window[peakIndex].time.length)),
    chg3: () {
      final value = changeOverDays(window, price, 3, today: now);
      return value == null ? null : _roundTo(value, 2);
    }(),
    chg5: () {
      final value = changeOverDays(window, price, 5, today: now);
      return value == null ? null : _roundTo(value, 2);
    }(),
  );
}

/// 零帧起手的分组：按"曾经站上过的最高主线"归组（每只只归最高一组），
/// 与主线突破同一套主线口径，看的是"从多高摔下来的"。
int? zeroBaseStage(double? peakPct) => breakoutStage(peakPct);
