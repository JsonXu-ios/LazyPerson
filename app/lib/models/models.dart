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

double? _num(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString());
}
