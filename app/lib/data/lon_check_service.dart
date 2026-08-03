/// 八档局 LON 多头标记：日线、周线、月线三个周期上 lon 与 lonma 都比
/// 上一根高（整体向上），且最新一根 lon ≥ lonma（lonma 不压在 lon 上面），
/// 三周期全满足才 true（对齐 backend/app/lon_check.py::LonChecker）。
///
/// 日/周/月K 都走 frames 缓存→腾讯：LON 的 LONG 是累计序列、起点敏感，
/// 日线必须与 backend 一样用 420 天跨度（本地 sqlite 只有 90 天，不能用）。
/// 只对命中的股票计算；单只取数失败/数据不足默认 false。
library;

import 'dart:convert';

import '../logic/indicators.dart';
import '../logic/lon_check.dart';
import '../models/models.dart';
import 'local_store.dart';
import 'providers/tencent_provider.dart';

/// 各周期最少 bar 数：LON 的 LONG 是累计序列，SMA10/20 需要收敛
const lonMinBars = 25;

/// 各周期缓存最新一根允许的滞后（自然日），超过则重拉
/// （对齐 backend MAX_LAG_DAYS）
const lonMaxLagDays = {'day': 4, 'week': 11, 'month': 45};

/// 拉取跨度（自然日）：日线约 420 天、周线约 3 年、月线约 10 年，
/// 历史给足让指标收敛（对齐 backend FETCH_DAYS）
const lonFetchDays = {'day': 420, 'week': 1100, 'month': 4200};

class LonCheckService {
  final LocalStore store;
  final TencentProvider tencent;
  final DateTime Function() now;

  LonCheckService({
    required this.store,
    TencentProvider? tencent,
    DateTime Function()? nowFn,
  })  : tencent = tencent ?? TencentProvider(),
        now = nowFn ?? DateTime.now;

  /// 单只判定：日/周/月全满足才 true；任一周期数据不足或取数失败 → false
  /// （对齐 backend LonChecker._check_symbol：异常即 False）。
  Future<bool> lonOkFor(String symbol) async {
    try {
      for (final period in const ['day', 'week', 'month']) {
        if (!_trendOk(await _cachedBars(symbol, period))) return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  bool _trendOk(List<KlineBar> bars) {
    if (bars.length < lonMinBars) return false;
    final payload = computeLon(bars);
    return lonTrendOk(
        payload['lon'] ?? const [], payload['lonma'] ?? const []);
  }

  /// 周/月K：frames 缓存 → 腾讯。缓存键与 MarketRepository._frameKline
  /// 一致互相复用；最新一根滞后超过容忍（周11天/月45天）则重拉。
  Future<List<KlineBar>> _cachedBars(String symbol, String period) async {
    final cacheKey = 'kline:$symbol:$period:qfq';
    final cached = await store.readFrame(cacheKey, allowStale: true);
    if (cached != null) {
      final bars = _decodeBars(cached);
      if (bars.isNotEmpty && !_tooOld(bars.last, lonMaxLagDays[period]!)) {
        return bars;
      }
    }
    final start = now()
        .subtract(Duration(days: lonFetchDays[period]!))
        .toIso8601String()
        .substring(0, 10);
    final bars = await tencent.kline(symbol, period, start: start);
    if (bars.isEmpty) return const [];
    await store.writeFrame(
      cacheKey: cacheKey,
      dataType: 'kline_$period',
      payloadJson: jsonEncode([for (final bar in bars) bar.toJson()]),
      source: TencentProvider.source,
      symbol: symbol,
      period: period,
      // 与 MarketRepository 的周/月K TTL 一致，图表读同一份缓存
      ttl: const Duration(hours: 1),
    );
    return bars;
  }

  List<KlineBar> _decodeBars(CachedFrame frame) => [
        for (final row in frame.decode() as List)
          KlineBar.fromJson((row as Map).cast<String, Object?>()),
      ];

  bool _tooOld(KlineBar last, int maxLagDays) {
    final raw = last.time.length >= 10 ? last.time.substring(0, 10) : last.time;
    final day = DateTime.tryParse('${raw}T00:00:00');
    if (day == null) return true;
    return now().difference(day).inDays > maxLagDays;
  }
}
