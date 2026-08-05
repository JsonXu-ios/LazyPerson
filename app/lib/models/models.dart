/// 数据模型，字段与网页版 frontend/src/types.ts 及后端 models.py 对齐。
library;

class DataQuality {
  final String source;
  final bool fromCache;
  final DateTime? updatedAt;
  final bool stale;
  final bool fallback;
  final String message;
  final List<String> warnings;

  const DataQuality({
    required this.source,
    this.fromCache = false,
    this.updatedAt,
    this.stale = false,
    this.fallback = false,
    this.message = '',
    this.warnings = const [],
  });

  DataQuality copyWith({
    String? source,
    bool? fromCache,
    DateTime? updatedAt,
    bool? stale,
    bool? fallback,
    String? message,
    List<String>? warnings,
  }) {
    return DataQuality(
      source: source ?? this.source,
      fromCache: fromCache ?? this.fromCache,
      updatedAt: updatedAt ?? this.updatedAt,
      stale: stale ?? this.stale,
      fallback: fallback ?? this.fallback,
      message: message ?? this.message,
      warnings: warnings ?? this.warnings,
    );
  }
}

class SymbolItem {
  final String symbol;
  final String market;
  final String name;
  final String pinyinAbbr;

  const SymbolItem({
    required this.symbol,
    required this.market,
    required this.name,
    this.pinyinAbbr = '',
  });

  String get display => '$symbol.$market $name'.trim();

  Map<String, Object?> toRow() => {
        'symbol': symbol,
        'market': market,
        'name': name,
        'pinyin_abbr': pinyinAbbr,
      };

  factory SymbolItem.fromRow(Map<String, Object?> row) => SymbolItem(
        symbol: row['symbol'] as String,
        market: (row['market'] as String?) ?? '',
        name: (row['name'] as String?) ?? '',
        pinyinAbbr: (row['pinyin_abbr'] as String?) ?? '',
      );
}

class Quote {
  final String symbol;
  final String market;
  final String name;
  final String? tradeTime;
  final double? price;
  final double? open;
  final double? high;
  final double? low;
  final double? preClose;
  final double? pctChg;
  final double? change;
  final double? volume;
  final double? amount;
  final double? turnover;

  /// 总市值（亿元），八档局市值过滤用；行情源无该字段时为 null
  final double? marketCap;

  const Quote({
    required this.symbol,
    this.market = '',
    this.name = '',
    this.tradeTime,
    this.price,
    this.open,
    this.high,
    this.low,
    this.preClose,
    this.pctChg,
    this.change,
    this.volume,
    this.amount,
    this.turnover,
    this.marketCap,
  });

  Map<String, Object?> toJson() => {
        'symbol': symbol,
        'market': market,
        'name': name,
        'trade_time': tradeTime,
        'price': price,
        'open': open,
        'high': high,
        'low': low,
        'pre_close': preClose,
        'pct_chg': pctChg,
        'change': change,
        'volume': volume,
        'amount': amount,
        'turnover': turnover,
        'market_cap': marketCap,
      };

  factory Quote.fromJson(Map<String, Object?> json) => Quote(
        symbol: json['symbol'] as String,
        market: (json['market'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        tradeTime: json['trade_time'] as String?,
        price: _num(json['price']),
        open: _num(json['open']),
        high: _num(json['high']),
        low: _num(json['low']),
        preClose: _num(json['pre_close']),
        pctChg: _num(json['pct_chg']),
        change: _num(json['change']),
        volume: _num(json['volume']),
        amount: _num(json['amount']),
        turnover: _num(json['turnover']),
        marketCap: _num(json['market_cap']),
      );
}

class WatchlistItem {
  final String symbol;
  final String market;
  final String name;
  final String groupName;
  final int sortOrder;
  final String note;

  const WatchlistItem({
    required this.symbol,
    this.market = '',
    this.name = '',
    this.groupName = 'default',
    this.sortOrder = 0,
    this.note = '',
  });
}

class KlineBar {
  final String time;
  final double? open;
  final double? high;
  final double? low;
  final double? close;
  final double? volume;
  final double? amount;
  final double? pctChg;
  final double? turnover;

  const KlineBar({
    required this.time,
    this.open,
    this.high,
    this.low,
    this.close,
    this.volume,
    this.amount,
    this.pctChg,
    this.turnover,
  });

  bool get hasOhlc => open != null && high != null && low != null && close != null;

  Map<String, Object?> toJson() => {
        'time': time,
        'open': open,
        'high': high,
        'low': low,
        'close': close,
        'volume': volume,
        'amount': amount,
        'pct_chg': pctChg,
        'turnover': turnover,
      };

  factory KlineBar.fromJson(Map<String, Object?> json) => KlineBar(
        time: json['time'] as String,
        open: _num(json['open']),
        high: _num(json['high']),
        low: _num(json['low']),
        close: _num(json['close']),
        volume: _num(json['volume']),
        amount: _num(json['amount']),
        pctChg: _num(json['pct_chg']),
        turnover: _num(json['turnover']),
      );
}

/// indicators: group -> series name -> values（与 KlinePayload.indicators 对齐）
typedef IndicatorPayload = Map<String, Map<String, List<double?>>>;

class KlinePayload {
  final String symbol;
  final String period;
  final String adjust;
  final List<KlineBar> bars;
  final IndicatorPayload indicators;

  const KlinePayload({
    required this.symbol,
    required this.period,
    this.adjust = 'qfq',
    this.bars = const [],
    this.indicators = const {},
  });

  KlinePayload copyWith({List<KlineBar>? bars, IndicatorPayload? indicators}) {
    return KlinePayload(
      symbol: symbol,
      period: period,
      adjust: adjust,
      bars: bars ?? this.bars,
      indicators: indicators ?? this.indicators,
    );
  }
}

// ---------- 财务（对齐 frontend/src/types.ts 与 backend eastmoney_adapter.py） ----------

class FundamentalValuation {
  final double? price;

  /// 市盈率（动态）
  final double? pe;
  final double? peTtm;
  final double? pb;

  /// 总市值（元）
  final double? marketCap;
  final double? floatMarketCap;

  const FundamentalValuation({
    this.price,
    this.pe,
    this.peTtm,
    this.pb,
    this.marketCap,
    this.floatMarketCap,
  });

  Map<String, Object?> toJson() => {
        'price': price,
        'pe': pe,
        'pe_ttm': peTtm,
        'pb': pb,
        'market_cap': marketCap,
        'float_market_cap': floatMarketCap,
      };

  factory FundamentalValuation.fromJson(Map<String, Object?> json) =>
      FundamentalValuation(
        price: _num(json['price']),
        pe: _num(json['pe']),
        peTtm: _num(json['pe_ttm']),
        pb: _num(json['pb']),
        marketCap: _num(json['market_cap']),
        floatMarketCap: _num(json['float_market_cap']),
      );
}

class FundamentalReport {
  final String reportDate;

  /// 例："2025年 年报"
  final String reportType;
  final String noticeDate;
  final double? eps;
  final double? deductEps;
  final double? bps;
  final double? revenue;
  final double? revenueYoy;
  final double? parentNetprofit;
  final double? parentNetprofitYoy;
  final double? deductParentNetprofit;

  /// 净利润（含少数股东）= 利润总额 - 所得税
  final double? netprofit;
  final double? totalProfit;
  final double? incomeTax;
  final double? roe;
  final double? grossMargin;
  final double? operatingCashflowPs;

  const FundamentalReport({
    required this.reportDate,
    this.reportType = '',
    this.noticeDate = '',
    this.eps,
    this.deductEps,
    this.bps,
    this.revenue,
    this.revenueYoy,
    this.parentNetprofit,
    this.parentNetprofitYoy,
    this.deductParentNetprofit,
    this.netprofit,
    this.totalProfit,
    this.incomeTax,
    this.roe,
    this.grossMargin,
    this.operatingCashflowPs,
  });

  String get label => reportType.isNotEmpty ? reportType : reportDate;

  Map<String, Object?> toJson() => {
        'report_date': reportDate,
        'report_type': reportType,
        'notice_date': noticeDate,
        'eps': eps,
        'deduct_eps': deductEps,
        'bps': bps,
        'revenue': revenue,
        'revenue_yoy': revenueYoy,
        'parent_netprofit': parentNetprofit,
        'parent_netprofit_yoy': parentNetprofitYoy,
        'deduct_parent_netprofit': deductParentNetprofit,
        'netprofit': netprofit,
        'total_profit': totalProfit,
        'income_tax': incomeTax,
        'roe': roe,
        'gross_margin': grossMargin,
        'operating_cashflow_ps': operatingCashflowPs,
      };

  factory FundamentalReport.fromJson(Map<String, Object?> json) =>
      FundamentalReport(
        reportDate: (json['report_date'] as String?) ?? '',
        reportType: (json['report_type'] as String?) ?? '',
        noticeDate: (json['notice_date'] as String?) ?? '',
        eps: _num(json['eps']),
        deductEps: _num(json['deduct_eps']),
        bps: _num(json['bps']),
        revenue: _num(json['revenue']),
        revenueYoy: _num(json['revenue_yoy']),
        parentNetprofit: _num(json['parent_netprofit']),
        parentNetprofitYoy: _num(json['parent_netprofit_yoy']),
        deductParentNetprofit: _num(json['deduct_parent_netprofit']),
        netprofit: _num(json['netprofit']),
        totalProfit: _num(json['total_profit']),
        incomeTax: _num(json['income_tax']),
        roe: _num(json['roe']),
        grossMargin: _num(json['gross_margin']),
        operatingCashflowPs: _num(json['operating_cashflow_ps']),
      );
}

class FundamentalDividend {
  final String reportDate;
  final String plan;
  final String progress;

  /// 每 10 股税前派息（元）
  final double? pretaxBonus;

  /// 每 10 股送股
  final double? bonusRatio;

  /// 每 10 股转增
  final double? itRatio;

  /// 股息率（小数）
  final double? dividendRatio;
  final String planNoticeDate;
  final String equityRecordDate;
  final String exDividendDate;

  const FundamentalDividend({
    required this.reportDate,
    this.plan = '',
    this.progress = '',
    this.pretaxBonus,
    this.bonusRatio,
    this.itRatio,
    this.dividendRatio,
    this.planNoticeDate = '',
    this.equityRecordDate = '',
    this.exDividendDate = '',
  });

  Map<String, Object?> toJson() => {
        'report_date': reportDate,
        'plan': plan,
        'progress': progress,
        'pretax_bonus': pretaxBonus,
        'bonus_ratio': bonusRatio,
        'it_ratio': itRatio,
        'dividend_ratio': dividendRatio,
        'plan_notice_date': planNoticeDate,
        'equity_record_date': equityRecordDate,
        'ex_dividend_date': exDividendDate,
      };

  factory FundamentalDividend.fromJson(Map<String, Object?> json) =>
      FundamentalDividend(
        reportDate: (json['report_date'] as String?) ?? '',
        plan: (json['plan'] as String?) ?? '',
        progress: (json['progress'] as String?) ?? '',
        pretaxBonus: _num(json['pretax_bonus']),
        bonusRatio: _num(json['bonus_ratio']),
        itRatio: _num(json['it_ratio']),
        dividendRatio: _num(json['dividend_ratio']),
        planNoticeDate: (json['plan_notice_date'] as String?) ?? '',
        equityRecordDate: (json['equity_record_date'] as String?) ?? '',
        exDividendDate: (json['ex_dividend_date'] as String?) ?? '',
      );
}

class Fundamentals {
  final String symbol;
  final String name;
  final FundamentalValuation valuation;
  final List<FundamentalReport> reports;
  final List<FundamentalDividend> dividends;
  final List<String> warnings;

  const Fundamentals({
    required this.symbol,
    this.name = '',
    this.valuation = const FundamentalValuation(),
    this.reports = const [],
    this.dividends = const [],
    this.warnings = const [],
  });

  FundamentalReport? get latestReport =>
      reports.isEmpty ? null : reports.first;

  Map<String, Object?> toJson() => {
        'symbol': symbol,
        'name': name,
        'valuation': valuation.toJson(),
        'reports': [for (final item in reports) item.toJson()],
        'dividends': [for (final item in dividends) item.toJson()],
        'warnings': warnings,
      };

  factory Fundamentals.fromJson(Map<String, Object?> json) => Fundamentals(
        symbol: (json['symbol'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        valuation: json['valuation'] is Map
            ? FundamentalValuation.fromJson(
                (json['valuation'] as Map).cast<String, Object?>())
            : const FundamentalValuation(),
        reports: [
          for (final row in (json['reports'] as List? ?? const []))
            FundamentalReport.fromJson((row as Map).cast<String, Object?>()),
        ],
        dividends: [
          for (final row in (json['dividends'] as List? ?? const []))
            FundamentalDividend.fromJson((row as Map).cast<String, Object?>()),
        ],
        warnings: [
          for (final item in (json['warnings'] as List? ?? const []))
            '$item',
        ],
      );
}

double? _num(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}

/// 板块排行的一行（行业或概念），对齐 backend/app/sectors.py 的板块行结构
class SectorBoard {
  final String code;
  final String name;

  /// industry | concept
  final String kind;
  final double? pctChg;
  final double? amount;
  final int? upCount;
  final int? downCount;

  /// 领涨股名称与代码
  final String leader;
  final String leaderSymbol;
  final double? leaderPct;

  const SectorBoard({
    required this.code,
    required this.name,
    required this.kind,
    this.pctChg,
    this.amount,
    this.upCount,
    this.downCount,
    this.leader = '',
    this.leaderSymbol = '',
    this.leaderPct,
  });

  Map<String, Object?> toJson() => {
        'code': code,
        'name': name,
        'kind': kind,
        'pct_chg': pctChg,
        'amount': amount,
        'up_count': upCount,
        'down_count': downCount,
        'leader': leader,
        'leader_symbol': leaderSymbol,
        'leader_pct': leaderPct,
      };

  factory SectorBoard.fromJson(Map<String, Object?> json) => SectorBoard(
        code: (json['code'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        kind: (json['kind'] as String?) ?? '',
        pctChg: _num(json['pct_chg']),
        amount: _num(json['amount']),
        upCount: _num(json['up_count'])?.toInt(),
        downCount: _num(json['down_count'])?.toInt(),
        leader: (json['leader'] as String?) ?? '',
        leaderSymbol: (json['leader_symbol'] as String?) ?? '',
        leaderPct: _num(json['leader_pct']),
      );
}

/// 板块成分股（总市值单位亿元）
class SectorConstituent {
  final String symbol;
  final String name;
  final double? price;
  final double? pctChg;
  final double? amount;
  final double? marketCap;

  const SectorConstituent({
    required this.symbol,
    required this.name,
    this.price,
    this.pctChg,
    this.amount,
    this.marketCap,
  });

  Map<String, Object?> toJson() => {
        'symbol': symbol,
        'name': name,
        'price': price,
        'pct_chg': pctChg,
        'amount': amount,
        'market_cap': marketCap,
      };

  factory SectorConstituent.fromJson(Map<String, Object?> json) =>
      SectorConstituent(
        symbol: (json['symbol'] as String?) ?? '',
        name: (json['name'] as String?) ?? '',
        price: _num(json['price']),
        pctChg: _num(json['pct_chg']),
        amount: _num(json['amount']),
        marketCap: _num(json['market_cap']),
      );
}

/// 个股所属板块的一条引用（slist 返回，行业/概念/地域混在一起）
class StockBoardRef {
  final String code;
  final String name;
  final double? pctChg;

  const StockBoardRef({required this.code, required this.name, this.pctChg});
}

/// 个股的行业与概念（概念已按东财概念板块全集过滤，地域/指数成分等噪声不算）
class StockSectors {
  final String symbol;

  /// 所属行业名（东财 f127），如"白酒Ⅱ"
  final String industry;

  /// 所属概念板块名（东财口径，按 slist 返回顺序）
  final List<String> concepts;

  /// 其中命中今日热点概念榜的板块名
  final List<String> hotConcepts;

  const StockSectors({
    required this.symbol,
    this.industry = '',
    this.concepts = const [],
    this.hotConcepts = const [],
  });

  bool get isEmpty => industry.isEmpty && concepts.isEmpty;

  /// 所属概念里有今日热点
  bool get hot => hotConcepts.isNotEmpty;

  Map<String, Object?> toJson() => {
        'symbol': symbol,
        'industry': industry,
        'concepts': concepts,
        'hot_concepts': hotConcepts,
      };

  factory StockSectors.fromJson(Map<String, Object?> json) => StockSectors(
        symbol: (json['symbol'] as String?) ?? '',
        industry: (json['industry'] as String?) ?? '',
        concepts: [
          for (final item in (json['concepts'] as List? ?? const [])) '$item',
        ],
        hotConcepts: [
          for (final item in (json['hot_concepts'] as List? ?? const []))
            '$item',
        ],
      );
}

/// 今日热点板块：行业榜 + 概念榜（都按涨幅降序）
class HotSectors {
  final List<SectorBoard> industries;
  final List<SectorBoard> concepts;

  const HotSectors({this.industries = const [], this.concepts = const []});

  bool get isEmpty => industries.isEmpty && concepts.isEmpty;
}
