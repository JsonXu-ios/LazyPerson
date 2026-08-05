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

/// 批量校验时的并发路数：每只要拉日/周/月三个周期（缓存未命中时三轮腾讯
/// 往返），6 路已经把网络吃满，再高只会互相排队/触发限流
const lonFetchConcurrency = 6;

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

  /// 批量校验（八档局 lon 阶段用）：按 [concurrency] 路并发跑 [lonOkFor]，
  /// 命中周期缓存的股票不发请求。单只失败/抛错记 false，不影响其他。
  /// 返回 symbol → 是否 LON 多头。
  ///
  /// 串行版在命中 700 只时是 700×最多 3 轮腾讯往返，实测 6~12 分钟；
  /// 6 路并发后 ≈ 117 轮，1~2 分钟（缓存命中的更快）。
  Future<Map<String, bool>> lonOkForMany(
    List<String> symbols, {
    int concurrency = lonFetchConcurrency,
    void Function(String symbol, bool ok)? onEach,
    bool Function()? shouldStop,
  }) async {
    final result = <String, bool>{};
    if (symbols.isEmpty) return result;
    final queue = symbols.iterator;
    Future<void> worker() async {
      // Iterator 在单 isolate 事件循环内串行推进，无并发竞争
      while (queue.moveNext()) {
        if (shouldStop?.call() ?? false) return; // 扫描被取消/重启，别再打网络
        final symbol = queue.current;
        var ok = false;
        try {
          ok = await lonOkFor(symbol);
        } catch (_) {
          ok = false; // 取数失败保持默认 false
        }
        result[symbol] = ok;
        onEach?.call(symbol, ok);
      }
    }

    final lanes = concurrency < 1 ? 1 : concurrency;
    await Future.wait([for (var i = 0; i < lanes; i++) worker()]);
    return result;
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
