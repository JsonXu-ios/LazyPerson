/// 八档局基本面标记：分红 / 净利润 / 估市值。
/// - dividendRecent：近一年有分红（含已公告未除息的今年分红）
/// - profitOk：最新报告期归母净利润 ≥ 0
/// - revenueOk：最新报告期累计营收按报告期年化后 ×10 > 总市值
///
/// 口径逐条对齐 backend/app/fundamentals.py（v2：估市值/净利润拆分为独立
/// 条件，按最新已披露报告期年化）；差别只有一处：backend 用净利率反推营收
/// （baostock 营收字段常缺失），东财业绩报表直接给 TOTAL_OPERATE_INCOME，
/// 这里直接用营收判定。
/// 只对命中的股票取数（约一两百只），结果按股票缓存进 app_state，3 天有效。
library;

import 'dart:convert';

import '../models/models.dart';
import 'local_store.dart';
import 'providers/eastmoney_fundamentals_provider.dart';

/// 缓存 3 天（对齐 backend FUND_CACHE_DAYS）
const fundCacheDays = 3;

/// 缓存 key 前缀（对齐 backend STATE_PREFIX；
/// v2: 估市值/净利润拆分为独立条件，按最新报告期年化，多存 revenue_ok）
const fundStatePrefix = 'fundamentals:v2:';

/// 批量补基本面标记时的并发路数（每只两轮东财往返：分红 + 业绩报表；
/// 与 sectorFetchConcurrency 同量级，再高东财会限流）
const fundamentalsFetchConcurrency = 7;

/// 按报告期年化系数：一季报×4、半年报×2、三季报×4/3、年报×1
/// （财报数据为年内累计值；对齐 backend annualize_factor）。
double? annualizeFactor(String? statDate) {
  if (statDate == null || statDate.length < 7) return null;
  final month = int.tryParse(statDate.substring(5, 7));
  return const {3: 4.0, 6: 2.0, 9: 4.0 / 3.0, 12: 1.0}[month];
}

/// 估市值：最新报告期累计营收年化后 ×10 > 总市值。
/// 营收/市值任一缺失或非正、报告期无法识别 → 不通过；
/// 市值单位亿元，×1e8 转元比较（对齐 backend revenue_condition）。
bool revenueCondition(double? revenue, String? statDate, double? marketCapYi) {
  final factor = annualizeFactor(statDate);
  if (factor == null) return false;
  if (revenue == null || revenue <= 0) return false;
  if (marketCapYi == null || marketCapYi <= 0) return false;
  return revenue * factor * 10 > marketCapYi * 1e8;
}

/// 净利润：最新报告期归母净利润 ≥ 0。缺失视为不通过
/// （对齐 backend profit_condition）。
bool profitCondition(double? parentNetProfit) =>
    parentNetProfit != null && parentNetProfit >= 0;

/// 近一年有分红：除权除息日在（今日−365天）之后即算；
/// 已公告未除息（日期在未来，或只有预案公告日）的今年分红也算。
bool dividendCondition(List<String> operateDates, DateTime today) {
  final cutoff = today.subtract(const Duration(days: 365));
  for (final raw in operateDates) {
    final text = raw.length >= 10 ? raw.substring(0, 10) : raw;
    final day = DateTime.tryParse(text);
    if (day == null) continue;
    if (!day.isBefore(cutoff)) return true;
  }
  return false;
}

/// 最近已结束的报告期（新→旧，最多 4 期），如 8 月 →
/// [06-30, 03-31, 去年12-31, 去年09-30]
/// （对齐 backend FundamentalsFetcher._latest_report 的候选序列）。
List<String> latestReportCandidates(DateTime today) {
  const quarterEnds = {1: '03-31', 2: '06-30', 3: '09-30', 4: '12-31'};
  final candidates = <String>[];
  for (final year in [today.year, today.year - 1]) {
    for (var quarter = 4; quarter >= 1; quarter--) {
      final quarterEnd =
          DateTime(year, quarter * 3, 1).add(const Duration(days: 31));
      if (quarterEnd.isAfter(today)) continue; // 报告期还没结束
      candidates.add('$year-${quarterEnds[quarter]}');
      if (candidates.length == 4) return candidates;
    }
  }
  return candidates;
}

/// 单只股票的基本面标记
class FundamentalsMarks {
  final bool dividendRecent;
  final bool profitOk;
  final bool revenueOk;

  const FundamentalsMarks({
    required this.dividendRecent,
    required this.profitOk,
    required this.revenueOk,
  });
}

/// 按命中股票补 dividendRecent / profitOk / revenueOk 标记，带 app_state
/// 缓存（对齐 backend/app/fundamentals.py::FundamentalsFetcher）。
class FundamentalsService {
  final LocalStore store;
  final EastmoneyFundamentalsProvider provider;
  final DateTime Function() now;

  FundamentalsService({
    required this.store,
    EastmoneyFundamentalsProvider? provider,
    DateTime Function()? nowFn,
  })  : provider = provider ?? EastmoneyFundamentalsProvider(),
        now = nowFn ?? DateTime.now;

  DateTime get _today {
    final day = now();
    return DateTime(day.year, day.month, day.day);
  }

  /// 单只标记：缓存命中直接用（3 天），否则拉东财并写缓存。
  /// 取数失败向上抛，由调用方兜底成 false（失败不写缓存，下次重试）。
  Future<FundamentalsMarks> marksFor(String symbol, double? marketCapYi) async {
    final cached = await _readCache(symbol);
    if (cached != null) return cached;
    final dividend = await _fetchDividend(symbol);
    // 最新已披露报告期：无财报数据时 profitOk/revenueOk 均不通过
    final report = await _latestReport(symbol);
    final marks = FundamentalsMarks(
      dividendRecent: dividend,
      profitOk: profitCondition(report?.parentNetprofit),
      revenueOk:
          revenueCondition(report?.revenue, report?.reportDate, marketCapYi),
    );
    await _writeCache(symbol, marks);
    return marks;
  }

  /// 只读缓存（八档局纯本地扫描用）：缓存未命中/已过期返回 null = “未知”，
  /// 由调用方标成第三态而不是 false。绝不发网络请求。
  Future<FundamentalsMarks?> cachedMarks(String symbol) => _readCache(symbol);

  /// 批量只读缓存：一次前缀查询拿走整张表再按 [symbols] 过滤，
  /// 比逐只 getState 少几百上千次 sqlite 往返。绝不发网络请求。
  Future<Map<String, FundamentalsMarks>> cachedMarksForMany(
      List<String> symbols) async {
    if (symbols.isEmpty) return {};
    final wanted = symbols.toSet();
    final raw = await store.getStatesWithPrefix(fundStatePrefix);
    final result = <String, FundamentalsMarks>{};
    for (final entry in raw.entries) {
      if (!wanted.contains(entry.key)) continue;
      final marks = _decodeCache(entry.value);
      if (marks != null) result[entry.key] = marks;
    }
    return result;
  }

  /// 批量补标记（八档局“补充数据”按钮用）：按 [concurrency] 路并发跑
  /// [marksFor]，命中 3 天缓存的股票不发请求。单只失败不进结果集，
  /// 由调用方保持默认 false。返回 symbol → 标记（缺失即取数失败）。
  ///
  /// 串行版在命中 700 只时是 700×(分红+财报两轮 RTT)，实测 5~10 分钟；
  /// 7 路并发后 ≈ 100 轮，40~90 秒。
  Future<Map<String, FundamentalsMarks>> marksForMany(
    List<String> symbols, {
    double? Function(String symbol)? marketCapOf,
    int concurrency = fundamentalsFetchConcurrency,
    void Function(String symbol, FundamentalsMarks? marks)? onEach,
    bool Function()? shouldStop,
  }) async {
    final result = <String, FundamentalsMarks>{};
    if (symbols.isEmpty) return result;
    final queue = symbols.iterator;
    Future<void> worker() async {
      // Iterator 在单 isolate 事件循环内串行推进，无并发竞争
      while (queue.moveNext()) {
        if (shouldStop?.call() ?? false) return; // 扫描被取消/重启，别再打网络
        final symbol = queue.current;
        FundamentalsMarks? marks;
        try {
          marks = await marksFor(symbol, marketCapOf?.call(symbol));
          result[symbol] = marks;
        } catch (_) {
          marks = null; // 取数失败：不写结果，调用方保持默认 false
        }
        onEach?.call(symbol, marks);
      }
    }

    final lanes = concurrency < 1 ? 1 : concurrency;
    await Future.wait([for (var i = 0; i < lanes; i++) worker()]);
    return result;
  }

  /// 现金分红>0 的记录取除权除息日，缺除息日（已公告未实施）用预案公告日
  /// （对齐 backend：dividOperateDate or dividPlanAnnounceDate）。
  Future<bool> _fetchDividend(String symbol) async {
    final rows = await provider.dividends(symbol);
    final dates = <String>[
      for (final row in rows)
        if (row.pretaxBonus != null && row.pretaxBonus! > 0)
          row.exDividendDate.isNotEmpty
              ? row.exDividendDate
              : row.planNoticeDate,
    ];
    return dividendCondition(dates, _today);
  }

  /// 从最近已结束的报告期往回试（最多 4 期），取第一个有披露数据的。
  Future<FundamentalReport?> _latestReport(String symbol) async {
    for (final reportDate in latestReportCandidates(_today)) {
      final report = await provider.reportAt(symbol, reportDate);
      if (report != null) return report;
    }
    return null;
  }

  Future<FundamentalsMarks?> _readCache(String symbol) async {
    final raw = await store.getState('$fundStatePrefix$symbol');
    return raw == null ? null : _decodeCache(raw);
  }

  /// 解析一条缓存；过期/损坏都返回 null（= 未知）
  FundamentalsMarks? _decodeCache(String raw) {
    try {
      final data = (jsonDecode(raw) as Map).cast<String, Object?>();
      final checked = DateTime.parse(data['checked_at'] as String);
      if (_today.difference(checked).inDays > fundCacheDays) return null;
      return FundamentalsMarks(
        dividendRecent: (data['dividend_recent'] as bool?) ?? false,
        profitOk: (data['profit_ok'] as bool?) ?? false,
        revenueOk: (data['revenue_ok'] as bool?) ?? false,
      );
    } catch (_) {
      return null; // 缓存损坏按无缓存处理
    }
  }

  Future<void> _writeCache(String symbol, FundamentalsMarks marks) =>
      store.setState(
        '$fundStatePrefix$symbol',
        jsonEncode({
          'checked_at': _today.toIso8601String().substring(0, 10),
          'dividend_recent': marks.dividendRecent,
          'profit_ok': marks.profitOk,
          'revenue_ok': marks.revenueOk,
        }),
      );
}
