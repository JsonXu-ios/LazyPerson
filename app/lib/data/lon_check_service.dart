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

/// LON 结论缓存 key 前缀（app_state）。八档局改成纯本地扫描后，扫描阶段
/// 只读这份结论，不再解 400 根周/月 K 重算——一次前缀查询就能拿到全部。
const lonResultPrefix = 'lon:v1:';

/// 结论缓存有效天数：日线换一根结论就可能变，只当天有效
const lonResultCacheDays = 1;

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

  /// 单只判定：日/周/月全满足才 true；任一周期数据不足 → false，结论写缓存。
  /// 取数失败向上抛（由 [lonOkForMany] 兜成 null = 未知，下次可重试）。
  Future<bool> lonOkFor(String symbol) async {
    for (final period in const ['day', 'week', 'month']) {
      if (!_trendOk(await _cachedBars(symbol, period))) {
        await _writeResult(symbol, false);
        return false;
      }
    }
    await _writeResult(symbol, true);
    return true;
  }

  /// 只读结论缓存（八档局纯本地扫描用）：无缓存/过期返回 null = “未知”。
  /// 绝不发网络请求。
  Future<bool?> cachedOk(String symbol) async {
    final raw = await store.getState('$lonResultPrefix$symbol');
    return raw == null ? null : _decodeResult(raw);
  }

  /// 批量只读结论缓存：一次前缀查询，绝不发网络请求
  Future<Map<String, bool>> cachedOkForMany(List<String> symbols) async {
    if (symbols.isEmpty) return {};
    final wanted = symbols.toSet();
    final raw = await store.getStatesWithPrefix(lonResultPrefix);
    final result = <String, bool>{};
    for (final entry in raw.entries) {
      if (!wanted.contains(entry.key)) continue;
      final ok = _decodeResult(entry.value);
      if (ok != null) result[entry.key] = ok;
    }
    return result;
  }

  /// 批量校验（八档局“补充数据”按钮用）：按 [concurrency] 路并发跑
  /// [lonOkFor]，命中周期缓存的股票不发请求。单只取数失败 onEach 收到 null
  /// （未知，可再点一次补），不影响其他。返回 symbol → 是否 LON 多头
  /// （取数失败的不进结果集）。
  ///
  /// 串行版在命中 700 只时是 700×最多 3 轮腾讯往返，实测 6~12 分钟；
  /// 6 路并发后 ≈ 117 轮，1~2 分钟（缓存命中的更快）。
  Future<Map<String, bool>> lonOkForMany(
    List<String> symbols, {
    int concurrency = lonFetchConcurrency,
    void Function(String symbol, bool? ok)? onEach,
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
        bool? ok;
        try {
          ok = await lonOkFor(symbol);
          result[symbol] = ok;
        } catch (_) {
          ok = null; // 取数失败：不写结果，调用方保持“未知”
        }
        onEach?.call(symbol, ok);
      }
    }

    final lanes = concurrency < 1 ? 1 : concurrency;
    await Future.wait([for (var i = 0; i < lanes; i++) worker()]);
    return result;
  }

  Future<void> _writeResult(String symbol, bool ok) => store.setState(
        '$lonResultPrefix$symbol',
        jsonEncode({
          'checked_at': now().toIso8601String().substring(0, 10),
          'lon_ok': ok,
        }),
      );

  bool? _decodeResult(String raw) {
    try {
      final data = (jsonDecode(raw) as Map).cast<String, Object?>();
      final checked = DateTime.parse(data['checked_at'] as String);
      final today = now();
      if (DateTime(today.year, today.month, today.day)
              .difference(checked)
              .inDays >
          lonResultCacheDays) {
        return null;
      }
      return data['lon_ok'] as bool?;
    } catch (_) {
      return null; // 缓存损坏按无缓存处理
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
