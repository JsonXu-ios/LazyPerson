/// 八档局基本面标记：分红（近一年，含已公告未除息的今年分红）与净利润
/// （归母净利润≥0 且 今年一季度营收×4×10 > 总市值）。
///
/// 口径逐条对齐 backend/app/fundamentals.py；差别只有一处：backend 用
/// 净利率反推营收是因为 baostock 一季报缺营收字段，东财业绩报表直接给
/// TOTAL_OPERATE_INCOME，这里直接用营收判定。
/// 只对命中的股票取数（约一两百只），结果按股票缓存进 app_state，3 天有效。
library;

import 'dart:convert';

import 'local_store.dart';
import 'providers/eastmoney_fundamentals_provider.dart';

/// 缓存 3 天（对齐 backend FUND_CACHE_DAYS）
const fundCacheDays = 3;

/// 缓存 key 前缀（对齐 backend STATE_PREFIX；
/// 与个股详情页整包缓存 'fundamentals:{symbol}' 不冲突）
const fundStatePrefix = 'fundamentals:v1:';

/// 净利润筛选：归母净利润≥0 且 一季度营收×4×10 > 总市值。
/// 营收/市值任一缺失或非正视为不通过；市值单位亿元，×1e8 转元比较。
bool profitCondition(
    double? parentNetProfit, double? revenue, double? marketCapYi) {
  if (parentNetProfit == null || parentNetProfit < 0) return false;
  if (revenue == null || revenue <= 0) return false;
  if (marketCapYi == null || marketCapYi <= 0) return false;
  return revenue * 4 * 10 > marketCapYi * 1e8;
}

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

/// 单只股票的基本面标记
class FundamentalsMarks {
  final bool dividendRecent;
  final bool profitOk;

  const FundamentalsMarks({
    required this.dividendRecent,
    required this.profitOk,
  });
}

/// 按命中股票补 dividendRecent / profitOk 标记，带 app_state 缓存
/// （对齐 backend/app/fundamentals.py::FundamentalsFetcher）。
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
    final marks = FundamentalsMarks(
      dividendRecent: await _fetchDividend(symbol),
      profitOk: await _fetchProfit(symbol, marketCapYi),
    );
    await _writeCache(symbol, marks);
    return marks;
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

  Future<bool> _fetchProfit(String symbol, double? marketCapYi) async {
    final report = await provider.reportAt(symbol, '${_today.year}-03-31');
    if (report == null) return false; // 一季报未披露/缺失视为不通过
    return profitCondition(
        report.parentNetprofit, report.revenue, marketCapYi);
  }

  Future<FundamentalsMarks?> _readCache(String symbol) async {
    final raw = await store.getState('$fundStatePrefix$symbol');
    if (raw == null) return null;
    try {
      final data = (jsonDecode(raw) as Map).cast<String, Object?>();
      final checked = DateTime.parse(data['checked_at'] as String);
      if (_today.difference(checked).inDays > fundCacheDays) return null;
      return FundamentalsMarks(
        dividendRecent: (data['dividend_recent'] as bool?) ?? false,
        profitOk: (data['profit_ok'] as bool?) ?? false,
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
        }),
      );
}
