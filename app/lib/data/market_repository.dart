/// 面向 UI 的数据入口：本地优先 + 多源降级 + 数据质量标记。
/// 语义对齐 backend/app/services.py::MarketService。
library;

import 'dart:convert';

import '../logic/indicators.dart';
import '../models/models.dart';
import 'local_store.dart';
import 'provider_error.dart';
import 'providers/eastmoney_provider.dart';
import 'providers/tencent_provider.dart';
import 'providers/yahoo_provider.dart';
import 'symbol_utils.dart';
import 'sync_service.dart';

class QuotesResult {
  final List<Quote> quotes;
  final DataQuality quality;

  const QuotesResult(this.quotes, this.quality);
}

class KlineResult {
  final KlinePayload payload;
  final DataQuality quality;

  const KlineResult(this.payload, this.quality);
}

class MarketRepository {
  static const defaultIndicators = ['macd', 'lon'];
  static const _seededKey = 'watchlist_seeded';

  static const _quoteTtl = Duration(seconds: 10);
  static const _minuteTtl = Duration(seconds: 60);
  static const _globalDayTtl = Duration(hours: 1);

  final LocalStore store;
  final SyncService sync;
  final TencentProvider tencent;
  final YahooProvider yahoo;
  final DateTime Function() now;

  MarketRepository({
    required this.store,
    required this.sync,
    TencentProvider? tencent,
    YahooProvider? yahoo,
    DateTime Function()? now,
  })  : tencent = tencent ?? TencentProvider(),
        yahoo = yahoo ?? YahooProvider(),
        now = now ?? DateTime.now;

  static const defaultWatchlist = [
    WatchlistItem(symbol: '002138', market: 'SZ', name: '顺络电子', groupName: 'a_share', sortOrder: 1),
    WatchlistItem(symbol: '600519', market: 'SH', name: '贵州茅台', groupName: 'a_share', sortOrder: 2),
    WatchlistItem(symbol: '000001', market: 'SZ', name: '平安银行', groupName: 'a_share', sortOrder: 3),
    WatchlistItem(symbol: '300750', market: 'SZ', name: '宁德时代', groupName: 'a_share', sortOrder: 4),
    WatchlistItem(symbol: 'SPY', market: 'US', name: '标普500 ETF', groupName: 'us', sortOrder: 1, note: '美股'),
    WatchlistItem(symbol: 'QQQ', market: 'US', name: '纳指100 ETF', groupName: 'us', sortOrder: 2, note: '美股'),
    WatchlistItem(symbol: 'GC=F', market: 'FUT', name: 'COMEX 黄金期货', groupName: 'gold', sortOrder: 1, note: '黄金'),
    WatchlistItem(symbol: 'BTC-USD', market: 'CRYPTO', name: '比特币 / 美元', groupName: 'crypto', sortOrder: 1, note: '比特币'),
  ];

  static const builtinSymbols = [
    SymbolItem(symbol: 'SPY', market: 'US', name: '标普500 ETF'),
    SymbolItem(symbol: 'QQQ', market: 'US', name: '纳指100 ETF'),
    SymbolItem(symbol: 'GC=F', market: 'FUT', name: 'COMEX 黄金期货'),
    SymbolItem(symbol: 'BTC-USD', market: 'CRYPTO', name: '比特币 / 美元'),
    SymbolItem(symbol: 'AAPL', market: 'US', name: 'Apple 苹果'),
    SymbolItem(symbol: 'MSFT', market: 'US', name: 'Microsoft 微软'),
    SymbolItem(symbol: 'NVDA', market: 'US', name: 'NVIDIA 英伟达'),
    SymbolItem(symbol: 'TSLA', market: 'US', name: 'Tesla 特斯拉'),
    SymbolItem(symbol: 'GLD', market: 'US', name: '黄金 ETF'),
    SymbolItem(symbol: 'XAUUSD=X', market: 'FX', name: '现货黄金 / 美元'),
    SymbolItem(symbol: 'ETH-USD', market: 'CRYPTO', name: '以太坊 / 美元'),
  ];

  Future<void> ensureSeeded() async {
    await store.upsertSymbols(builtinSymbols);
    if (await store.getState(_seededKey) == '1') return;
    for (final item in defaultWatchlist) {
      await store.addWatchlist(item.symbol, item.groupName, note: item.note);
    }
    await store.setState(_seededKey, '1');
  }

  // ---------- 搜索 / 自选 ----------

  Future<List<SymbolItem>> searchSymbols(String query, {int limit = 8}) =>
      store.searchSymbols(query, limit: limit);

  Future<List<WatchlistItem>> listWatchlist() => store.listWatchlist();

  Future<void> addWatchlist(String symbol, String groupName) =>
      store.addWatchlist(normalizeSymbol(symbol), groupName);

  Future<void> removeWatchlist(String symbol) =>
      store.removeWatchlist(normalizeSymbol(symbol));

  // ---------- 实时行情 ----------

  Future<QuotesResult> realtimeQuotes(List<String> symbols,
      {bool refresh = false}) async {
    final clean = <String>[];
    for (final symbol in symbols) {
      final normalized = normalizeSymbol(symbol);
      if (normalized.isNotEmpty && !clean.contains(normalized)) {
        clean.add(normalized);
      }
    }
    if (clean.isEmpty) {
      return QuotesResult(const [], _quality('unknown'));
    }

    final aSymbols = clean.where(isAShareSymbol).toList();
    final globalSymbols = clean.where((s) => !isAShareSymbol(s)).toList();
    final quotes = <Quote>[];
    final qualities = <DataQuality>[];
    final warnings = <String>[];

    if (aSymbols.isNotEmpty) {
      final result = await _cachedQuotes(
        'quote:a:${(aSymbols.toList()..sort()).join(',')}',
        aSymbols,
        () => tencent.realtimeQuotes(aSymbols),
        TencentProvider.source,
        refresh: refresh,
      );
      if (result != null) {
        quotes.addAll(result.quotes);
        qualities.add(result.quality);
      } else {
        warnings.add('a_quotes_unavailable');
      }
    }
    if (globalSymbols.isNotEmpty) {
      final result = await _cachedQuotes(
        'quote:global:${(globalSymbols.toList()..sort()).join(',')}',
        globalSymbols,
        () => yahoo.realtimeQuotes(globalSymbols),
        YahooProvider.source,
        refresh: refresh,
      );
      if (result != null) {
        quotes.addAll(result.quotes);
        qualities.add(result.quality);
      } else {
        warnings.add('global_quotes_unavailable');
      }
    }

    if (quotes.isEmpty) {
      // 行情全部失败：用最新日 K 兜底（对齐 services.py 的 kline_fallback）
      final fallback = <Quote>[];
      for (final symbol in clean) {
        final bars = await store.getDailyBars(symbol);
        if (bars.isEmpty) continue;
        final latest = bars.last;
        final preClose = bars.length > 1 ? bars[bars.length - 2].close : null;
        fallback.add(Quote(
          symbol: symbol,
          tradeTime: latest.time,
          price: latest.close,
          open: latest.open,
          high: latest.high,
          low: latest.low,
          preClose: preClose,
          pctChg: latest.pctChg,
          change: latest.close != null && preClose != null
              ? latest.close! - preClose
              : null,
          volume: latest.volume,
          amount: latest.amount,
          turnover: latest.turnover,
        ));
      }
      if (fallback.isNotEmpty) {
        return QuotesResult(
          fallback,
          _quality('kline_fallback',
              fromCache: true,
              stale: true,
              fallback: true,
              warnings: ['realtime_unavailable', ...warnings]),
        );
      }
      throw ProviderError(warnings.join('; '));
    }

    quotes.sort((a, b) =>
        clean.indexOf(a.symbol).compareTo(clean.indexOf(b.symbol)));
    return QuotesResult(quotes, _combineQuality(qualities, warnings));
  }

  Future<QuotesResult?> _cachedQuotes(
    String cacheKey,
    List<String> expected,
    Future<List<Quote>> Function() fetcher,
    String source, {
    required bool refresh,
  }) async {
    if (!refresh) {
      final cached = await store.readFrame(cacheKey, allowStale: true);
      if (cached != null && !cached.stale) {
        return QuotesResult(_decodeQuotes(cached),
            _qualityFromFrame(cached, stale: false));
      }
    }
    try {
      final fetched = await fetcher();
      final found = fetched.map((quote) => normalizeSymbol(quote.symbol)).toSet();
      if (fetched.isEmpty || expected.any((s) => !found.contains(s))) {
        throw ProviderError('missing symbols', source);
      }
      await store.writeFrame(
        cacheKey: cacheKey,
        dataType: 'quote',
        payloadJson: jsonEncode(fetched.map((quote) => quote.toJson()).toList()),
        source: source,
        ttl: _quoteTtl,
      );
      return QuotesResult(fetched, _quality(source));
    } catch (_) {
      final cached = await store.readFrame(cacheKey, allowStale: true);
      if (cached != null) {
        return QuotesResult(
            _decodeQuotes(cached), _qualityFromFrame(cached, stale: true));
      }
      return null;
    }
  }

  List<Quote> _decodeQuotes(CachedFrame frame) => (frame.decode() as List)
      .map((row) => Quote.fromJson((row as Map).cast<String, Object?>()))
      .toList();

  // ---------- K 线 ----------

  Future<KlineResult> kline(
    String symbol,
    String period, {
    bool refresh = false,
    int? limit,
    List<String> indicators = defaultIndicators,
  }) async {
    final clean = normalizeSymbol(symbol);
    if (isAShareSymbol(clean) && period == 'day') {
      return _aShareDaily(clean, refresh: refresh, limit: limit, indicators: indicators);
    }
    return _frameKline(clean, period,
        refresh: refresh, limit: limit, indicators: indicators);
  }

  /// A 股日 K：本地 daily_bars 为唯一事实源；落后/强刷时先单只补齐
  Future<KlineResult> _aShareDaily(
    String symbol, {
    required bool refresh,
    int? limit,
    required List<String> indicators,
  }) async {
    var bars = await store.getDailyBars(symbol);
    final latest = bars.isNotEmpty ? bars.last.time : '';
    final lagging = latest.isEmpty ||
        now()
                .difference(DateTime.parse('${latest}T00:00:00'))
                .inDays >
            3;
    var source = 'local';
    var stale = false;
    final warnings = <String>[];

    if (refresh || lagging) {
      try {
        await sync.refreshSymbol(symbol);
        bars = await store.getDailyBars(symbol);
        source = TencentProvider.source;
      } catch (exc) {
        warnings.add('refresh:$exc');
        stale = bars.isNotEmpty;
        if (bars.isEmpty) rethrow;
      }
    }

    bars = _filterDailyTradingRows(bars);
    final payload = _buildPayload(symbol, 'day', 'qfq', bars, indicators, limit);
    return KlineResult(
      payload,
      _quality(source,
          fromCache: source == 'local', stale: stale, warnings: warnings),
    );
  }

  /// 分钟 K 与全球标的：frames 短期缓存 + 在线拉取
  Future<KlineResult> _frameKline(
    String symbol,
    String period, {
    required bool refresh,
    int? limit,
    required List<String> indicators,
  }) async {
    final isAShare = isAShareSymbol(symbol);
    final adjust = isAShare ? 'qfq' : 'none';
    final cacheKey = 'kline:$symbol:$period:$adjust';
    final ttl = period == 'day' ? _globalDayTtl : _minuteTtl;

    if (!refresh) {
      final cached = await store.readFrame(cacheKey, allowStale: false);
      if (cached != null) {
        final bars = _decodeBars(cached);
        return KlineResult(
          _buildPayload(symbol, period, adjust, bars, indicators, limit),
          _qualityFromFrame(cached, stale: false),
        );
      }
    }

    List<KlineBar>? bars;
    String source = 'unknown';
    final warnings = <String>[];
    final fetchers = isAShare
        ? <(String, Future<List<KlineBar>> Function())>[
            (TencentProvider.source, () => tencent.kline(symbol, period, adjust: adjust)),
            (EastmoneyProvider.source, () => sync.eastmoney.kline(symbol, period, adjust: adjust)),
          ]
        : <(String, Future<List<KlineBar>> Function())>[
            (YahooProvider.source, () => yahoo.kline(symbol, period)),
          ];
    for (final (name, fetcher) in fetchers) {
      try {
        final fetched = await fetcher();
        if (fetched.isEmpty) {
          warnings.add('$name:empty');
          continue;
        }
        bars = fetched;
        source = name;
        break;
      } catch (exc) {
        warnings.add('$name:$exc');
      }
    }

    if (bars == null) {
      final cached = await store.readFrame(cacheKey, allowStale: true);
      if (cached != null) {
        return KlineResult(
          _buildPayload(
              symbol, period, adjust, _decodeBars(cached), indicators, limit),
          _qualityFromFrame(cached, stale: true, warnings: warnings),
        );
      }
      throw ProviderError(
          warnings.isEmpty ? 'no provider returned data' : warnings.join('; '));
    }

    await store.writeFrame(
      cacheKey: cacheKey,
      dataType: period == 'day' ? 'kline_day' : 'kline_minute',
      payloadJson: jsonEncode(bars.map((bar) => bar.toJson()).toList()),
      source: source,
      symbol: symbol,
      period: period,
      ttl: ttl,
    );
    return KlineResult(
      _buildPayload(symbol, period, adjust, bars, indicators, limit),
      _quality(source, warnings: warnings),
    );
  }

  List<KlineBar> _decodeBars(CachedFrame frame) => (frame.decode() as List)
      .map((row) => KlineBar.fromJson((row as Map).cast<String, Object?>()))
      .toList();

  /// 对齐 services.py::_filter_daily_trading_rows：剔除周末与 OHLC 缺失行
  List<KlineBar> _filterDailyTradingRows(List<KlineBar> bars) {
    return bars.where((bar) {
      final date = DateTime.tryParse('${bar.time}T00:00:00');
      if (date == null) return false;
      if (date.weekday == DateTime.saturday || date.weekday == DateTime.sunday) {
        return false;
      }
      return bar.hasOhlc;
    }).toList();
  }

  KlinePayload _buildPayload(
    String symbol,
    String period,
    String adjust,
    List<KlineBar> bars,
    List<String> indicators,
    int? limit,
  ) {
    final fullIndicators =
        indicators.isEmpty ? <String, Map<String, List<double?>>>{} : computeIndicators(bars, indicators);
    var resultBars = bars;
    var resultIndicators = fullIndicators;
    if (limit != null && limit > 0 && bars.length > limit) {
      resultBars = bars.sublist(bars.length - limit);
      resultIndicators = fullIndicators.map((group, series) => MapEntry(
            group,
            series.map((name, values) => MapEntry(
                  name,
                  values.length > limit
                      ? values.sublist(values.length - limit)
                      : values,
                )),
          ));
    }
    return KlinePayload(
      symbol: symbol,
      period: period,
      adjust: adjust,
      bars: resultBars,
      indicators: resultIndicators,
    );
  }

  // ---------- 数据质量 ----------

  static String _messageFor(String source,
      {bool fromCache = false, bool stale = false, bool fallback = false}) {
    if (fallback) return '实时行情不可用，使用最新日 K 兜底';
    if (stale) return '缓存数据已过期，可能滞后';
    if (fromCache) return '使用本地缓存';
    switch (source) {
      case 'tencent':
        return '腾讯行情数据';
      case 'eastmoney':
        return '东方财富数据';
      case 'yahoo':
        return 'Yahoo Finance 数据';
      case 'local':
        return '本地数据';
      case 'mixed':
        return '多市场数据';
    }
    return '数据已更新';
  }

  DataQuality _quality(
    String source, {
    bool fromCache = false,
    bool stale = false,
    bool fallback = false,
    List<String> warnings = const [],
  }) {
    return DataQuality(
      source: source,
      fromCache: fromCache,
      updatedAt: now(),
      stale: stale,
      fallback: fallback,
      message: _messageFor(source,
          fromCache: fromCache, stale: stale, fallback: fallback),
      warnings: warnings,
    );
  }

  DataQuality _qualityFromFrame(CachedFrame frame,
      {required bool stale, List<String> warnings = const []}) {
    return DataQuality(
      source: frame.source,
      fromCache: true,
      updatedAt: frame.updatedAt,
      stale: stale,
      message: _messageFor(frame.source, fromCache: true, stale: stale),
      warnings: [...warnings, if (stale) 'stale_cache'],
    );
  }

  DataQuality _combineQuality(List<DataQuality> qualities, List<String> warnings) {
    if (qualities.length == 1 && warnings.isEmpty) return qualities.first;
    final allWarnings = <String>[...warnings];
    for (final quality in qualities) {
      allWarnings.addAll(quality.warnings);
    }
    return DataQuality(
      source: qualities.length == 1 ? qualities.first.source : 'mixed',
      fromCache: qualities.every((quality) => quality.fromCache),
      updatedAt: now(),
      stale: qualities.any((quality) => quality.stale),
      fallback: qualities.any((quality) => quality.fallback),
      message: _messageFor(qualities.length == 1 ? qualities.first.source : 'mixed'),
      warnings: allWarnings,
    );
  }
}
