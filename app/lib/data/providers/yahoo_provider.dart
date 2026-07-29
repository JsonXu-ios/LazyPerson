/// Yahoo Finance 数据源（美股/黄金/比特币），移植自 backend/app/providers/yahoo_adapter.py。
library;

import 'package:dio/dio.dart';

import '../../models/models.dart';
import '../provider_error.dart';
import '../symbol_utils.dart';

class YahooProvider {
  static const source = 'yahoo';

  final Dio _dio;

  YahooProvider([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'User-Agent': 'Mozilla/5.0'},
            ));

  Future<Map<String, dynamic>> _getChart(
      String symbol, Map<String, String> params) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        'https://query1.finance.yahoo.com/v8/finance/chart/${Uri.encodeComponent(normalizeSymbol(symbol))}',
        queryParameters: params,
      );
    } on DioException catch (exc) {
      throw ProviderError(exc.message ?? exc.toString(), source);
    }
    if (response.statusCode != 200) {
      throw ProviderError('HTTP ${response.statusCode}', source);
    }
    final chart = response.data?['chart'] as Map<String, dynamic>? ?? const {};
    final error = chart['error'];
    if (error != null) throw ProviderError('$error', source);
    final results = chart['result'] as List? ?? const [];
    if (results.isEmpty) throw ProviderError('empty chart result', source);
    return results.first as Map<String, dynamic>;
  }

  Future<List<Quote>> realtimeQuotes(List<String> symbols) async {
    final quotes = <Quote>[];
    for (final symbol in symbols) {
      final payload = await _getChart(symbol, {'range': '5d', 'interval': '1d'});
      final quote = _parseQuotePayload(payload);
      if (quote != null) quotes.add(quote);
    }
    return quotes;
  }

  Future<List<KlineBar>> kline(
    String symbol,
    String period, {
    String? start,
    String? end,
  }) async {
    const intervalMap = {
      'day': '1d',
      'week': '1wk',
      'month': '1mo',
      '1m': '1m',
      '5m': '5m',
      '15m': '15m',
      '30m': '30m',
      '60m': '60m',
    };
    // 日/周/月按自然日范围取数：日 900 天、周 2 年+、月 5 年+
    const rangeDays = {'day': 900, 'week': 800, 'month': 1900};
    final interval = intervalMap[period];
    if (interval == null) {
      throw ProviderError('Unsupported period $period', source);
    }

    final params = <String, String>{'interval': interval};
    final days = rangeDays[period];
    if (days != null) {
      params.addAll(_periodParams(start, end, defaultDays: days));
    } else {
      params['range'] = period == '1m' ? '5d' : '60d';
    }

    final payload = await _getChart(symbol, params);
    return _parseKlinePayload(payload, period);
  }

  Future<List<SymbolItem>> searchSymbols(String query, {int limit = 20}) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(
        'https://query1.finance.yahoo.com/v1/finance/search',
        queryParameters: {'q': query, 'quotesCount': '$limit', 'newsCount': '0'},
      );
    } on DioException catch (exc) {
      throw ProviderError(exc.message ?? exc.toString(), source);
    }
    if (response.statusCode != 200) {
      throw ProviderError('HTTP ${response.statusCode}', source);
    }
    final items = <SymbolItem>[];
    final seen = <String>{};
    for (final quote in (response.data?['quotes'] as List? ?? const [])) {
      if (quote is! Map<String, dynamic>) continue;
      final symbol = normalizeSymbol('${quote['symbol'] ?? ''}');
      final market = _searchMarket(quote, symbol);
      if (symbol.isEmpty || market.isEmpty || seen.contains(symbol)) continue;
      items.add(SymbolItem(
        symbol: symbol,
        market: market,
        name: '${quote['longname'] ?? quote['shortname'] ?? symbol}',
      ));
      seen.add(symbol);
      if (items.length >= limit) break;
    }
    return items;
  }
}

Map<String, String> _periodParams(String? start, String? end,
    {required int defaultDays}) {
  final endDt = _parseDate(end) ?? DateTime.now().toUtc();
  final startDt = _parseDate(start) ?? endDt.subtract(Duration(days: defaultDays));
  return {
    'period1': '${startDt.millisecondsSinceEpoch ~/ 1000}',
    'period2':
        '${endDt.add(const Duration(days: 1)).millisecondsSinceEpoch ~/ 1000}',
    'events': 'history',
  };
}

DateTime? _parseDate(String? value) {
  if (value == null || value.isEmpty) return null;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

/// 交易所时区偏移（秒），Yahoo meta 自带 gmtoffset，无需时区数据库
int _gmtOffsetSeconds(Map<String, dynamic> meta) =>
    (meta['gmtoffset'] as num?)?.toInt() ?? 0;

String _formatTime(num? timestamp, Map<String, dynamic> meta, String period) {
  if (timestamp == null) return '';
  final local = DateTime.fromMillisecondsSinceEpoch(timestamp.toInt() * 1000,
          isUtc: true)
      .add(Duration(seconds: _gmtOffsetSeconds(meta)));
  final date =
      '${local.year.toString().padLeft(4, '0')}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  if (period == 'day' || period == 'week' || period == 'month') return date;
  final time =
      '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  return '$date $time';
}

Quote? _parseQuotePayload(Map<String, dynamic> payload) {
  final meta = payload['meta'] as Map<String, dynamic>? ?? const {};
  final symbol = normalizeSymbol('${meta['symbol'] ?? ''}');
  final price = safeDouble(meta['regularMarketPrice']);
  final preClose =
      safeDouble(meta['previousClose']) ?? safeDouble(meta['chartPreviousClose']);
  if (symbol.isEmpty || price == null) return null;
  final change =
      preClose != null && preClose != 0 ? price - preClose : null;
  final pctChg = change != null && preClose != null && preClose != 0
      ? change / preClose * 100
      : null;
  final volume = safeDouble(meta['regularMarketVolume']);
  final market = guessMarket(symbol);
  return Quote(
    symbol: symbol,
    market: market.isNotEmpty ? market : '${meta['exchangeName'] ?? ''}',
    name: '${meta['longName'] ?? meta['shortName'] ?? symbol}',
    tradeTime: _formatTime(meta['regularMarketTime'] as num?, meta, 'minute'),
    price: price,
    open: safeDouble(meta['regularMarketOpen']),
    high: safeDouble(meta['regularMarketDayHigh']),
    low: safeDouble(meta['regularMarketDayLow']),
    preClose: preClose,
    pctChg: pctChg,
    change: change,
    volume: volume,
    amount: volume != null ? price * volume : null,
  );
}

String _searchMarket(Map<String, dynamic> quote, String symbol) {
  final quoteType = '${quote['quoteType'] ?? ''}'.toUpperCase();
  final exchange = '${quote['exchange'] ?? ''}'.toUpperCase();
  if (quoteType == 'CRYPTOCURRENCY' ||
      quoteType == 'CRYPTO' ||
      symbol.endsWith('-USD')) {
    return 'CRYPTO';
  }
  if (quoteType == 'FUTURE' || symbol.endsWith('=F')) return 'FUT';
  if (quoteType == 'CURRENCY' || symbol.endsWith('=X')) return 'FX';
  if (const {'EQUITY', 'ETF'}.contains(quoteType) &&
      const {'NMS', 'NYQ', 'ASE', 'PCX', 'BTS', 'NGM', 'NCM'}.contains(exchange)) {
    return 'US';
  }
  return '';
}

List<KlineBar> _parseKlinePayload(Map<String, dynamic> payload, String period) {
  final meta = payload['meta'] as Map<String, dynamic>? ?? const {};
  final timestamps = payload['timestamp'] as List? ?? const [];
  final quoteList =
      (payload['indicators'] as Map<String, dynamic>?)?['quote'] as List? ??
          const [];
  final quote = quoteList.isNotEmpty
      ? quoteList.first as Map<String, dynamic>
      : const <String, dynamic>{};
  final bars = <KlineBar>[];
  var previousClose = safeDouble(meta['chartPreviousClose']);
  for (var index = 0; index < timestamps.length; index++) {
    final close = safeDouble(_at(quote, 'close', index));
    double? pctChg;
    if (close != null && previousClose != null && previousClose != 0) {
      pctChg = (close - previousClose) / previousClose * 100;
    }
    final volume = safeDouble(_at(quote, 'volume', index));
    bars.add(KlineBar(
      time: _formatTime(timestamps[index] as num?, meta, period),
      open: safeDouble(_at(quote, 'open', index)),
      high: safeDouble(_at(quote, 'high', index)),
      low: safeDouble(_at(quote, 'low', index)),
      close: close,
      volume: volume,
      amount: close != null && volume != null ? close * volume : null,
      pctChg: pctChg,
    ));
    if (close != null) previousClose = close;
  }
  final byTime = <String, KlineBar>{};
  for (final bar in bars) {
    if (bar.time.isEmpty) continue;
    byTime.putIfAbsent(bar.time, () => bar);
  }
  return byTime.values.toList()..sort((a, b) => a.time.compareTo(b.time));
}

Object? _at(Map<String, dynamic> values, String key, int index) {
  final series = values[key] as List? ?? const [];
  return index < series.length ? series[index] : null;
}
