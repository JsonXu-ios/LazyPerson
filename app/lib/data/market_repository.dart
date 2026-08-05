/// 面向 UI 的数据入口：本地优先 + 多源降级 + 数据质量标记。
/// 语义对齐 backend/app/services.py::MarketService。
library;

import 'dart:convert';

import '../logic/indicators.dart';
import '../logic/market_panels.dart';
import '../models/models.dart';
import 'local_store.dart';
import 'provider_error.dart';
import 'providers/eastmoney_fundamentals_provider.dart';
import 'providers/eastmoney_provider.dart';
import 'providers/eastmoney_sector_provider.dart';
import 'providers/tencent_provider.dart';
import 'sector_service.dart';
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

  /// 历史版本种过美股/黄金/加密自选，删代码不会删数据，靠这个标记补一次清理
  static const _aShareOnlyKey = 'a_share_only_migrated';

  static const _quoteTtl = Duration(seconds: 10);
  static const _minuteTtl = Duration(seconds: 60);
  static const _barDayTtl = Duration(hours: 1);

  /// 财报日内不变，6 小时（对齐 backend FUNDAMENTALS_TTL_SECONDS）
  static const _fundamentalsTtl = Duration(hours: 6);

  final LocalStore store;
  final SyncService sync;
  final TencentProvider tencent;
  final EastmoneyFundamentalsProvider fundamentalsProvider;
  final EastmoneySectorProvider sectorProvider;
  final DateTime Function() now;

  MarketRepository({
    required this.store,
    required this.sync,
    TencentProvider? tencent,
    EastmoneyFundamentalsProvider? fundamentalsProvider,
    EastmoneySectorProvider? sectorProvider,
    DateTime Function()? now,
  })  : tencent = tencent ?? TencentProvider(),
        fundamentalsProvider =
            fundamentalsProvider ?? EastmoneyFundamentalsProvider(),
        sectorProvider = sectorProvider ?? EastmoneySectorProvider(),
        now = now ?? DateTime.now {
    sectors = SectorService(
      store: store,
      provider: this.sectorProvider,
      nowFn: this.now,
    );
  }

  /// 板块服务（热点榜/成分股/个股行业概念）。资产信息浮层、热点板块页与
  /// 八档局共用一份，缓存也共用。
  late final SectorService sectors;

  static const defaultWatchlist = [
    WatchlistItem(symbol: '002138', market: 'SZ', name: '顺络电子', groupName: aShareGroup, sortOrder: 1),
    WatchlistItem(symbol: '600519', market: 'SH', name: '贵州茅台', groupName: aShareGroup, sortOrder: 2),
    WatchlistItem(symbol: '000001', market: 'SZ', name: '平安银行', groupName: aShareGroup, sortOrder: 3),
    WatchlistItem(symbol: '300750', market: 'SZ', name: '宁德时代', groupName: aShareGroup, sortOrder: 4),
  ];

  Future<void> ensureSeeded() async {
    if (await store.getState(_aShareOnlyKey) != '1') {
      await store.purgeNonAShare();
      await store.setState(_aShareOnlyKey, '1');
    }
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

  /// 把行情里的名称/市场落进 symbols 表。自选列表的名称是 join symbols 拿的，
  /// 全市场同步没跑完时那张表还是空的，列表就只剩代码 —— 这里顺手补上。
  Future<void> rememberQuoteNames(List<Quote> quotes) async {
    final items = [
      for (final quote in quotes)
        if (quote.name.trim().isNotEmpty)
          SymbolItem(
            symbol: quote.symbol,
            market: quote.market,
            name: quote.name.trim(),
          ),
    ];
    if (items.isEmpty) return;
    await store.upsertSymbols(items);
  }

  Future<void> addWatchlist(String symbol, String groupName) =>
      store.addWatchlist(normalizeSymbol(symbol), groupName);

  Future<void> removeWatchlist(String symbol) =>
      store.removeWatchlist(normalizeSymbol(symbol));

  // ---------- 实时行情 ----------

  Future<QuotesResult> realtimeQuotes(List<String> symbols,
      {bool refresh = false}) async {
    // 只保留 A 股：历史自选里可能还残留美股/黄金/加密代码，
    // 它们会让 TencentProvider 抛错，进而整批行情失败退化成日 K 兜底
    final clean = <String>[];
    for (final symbol in symbols) {
      final normalized = normalizeSymbol(symbol);
      if (normalized.isNotEmpty &&
          isAShareSymbol(normalized) &&
          !clean.contains(normalized)) {
        clean.add(normalized);
      }
    }
    if (clean.isEmpty) {
      return QuotesResult(const [], _quality('unknown'));
    }

    final quotes = <Quote>[];
    final qualities = <DataQuality>[];
    final warnings = <String>[];

    final result = await _cachedQuotes(
      'quote:a:${(clean.toList()..sort()).join(',')}',
      clean,
      () => tencent.realtimeQuotes(clean),
      TencentProvider.source,
      refresh: refresh,
    );
    if (result != null) {
      quotes.addAll(result.quotes);
      qualities.add(result.quality);
    } else {
      warnings.add('a_quotes_unavailable');
    }

    if (quotes.isEmpty) {
      // 行情全部失败：用最新日 K 兜底（对齐 services.py 的 kline_fallback）
      final fallback = <Quote>[];
      for (final symbol in clean) {
        final bars = await store.getDailyBars(symbol);
        if (bars.isEmpty) continue;
        final latest = bars.last;
        final preClose = bars.length > 1 ? bars[bars.length - 2].close : null;
        final meta = await store.getSymbol(symbol);
        fallback.add(Quote(
          symbol: symbol,
          market: meta?.market ?? '',
          name: meta?.name ?? '',
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

  /// 周/月 K 与分钟 K：frames 短期缓存 + 在线拉取（日 K 走 _aShareDaily）
  Future<KlineResult> _frameKline(
    String symbol,
    String period, {
    required bool refresh,
    int? limit,
    required List<String> indicators,
  }) async {
    const adjust = 'qfq';
    final cacheKey = 'kline:$symbol:$period:$adjust';
    final isBarPeriod = period == 'day' || period == 'week' || period == 'month';
    final ttl = isBarPeriod ? _barDayTtl : _minuteTtl;

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
    final fetchers = <(String, Future<List<KlineBar>> Function())>[
      (TencentProvider.source, () => tencent.kline(symbol, period, adjust: adjust)),
      (EastmoneyProvider.source, () => sync.eastmoney.kline(symbol, period, adjust: adjust)),
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
      dataType: isBarPeriod ? 'kline_$period' : 'kline_minute',
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

  // ---------- 财务 ----------

  /// 分红 + 业绩 + 估值。仅 A 股有；结构是嵌套的，用 state 表存 JSON 做 TTL 缓存
  /// （语义对齐 backend/app/services.py::MarketService.fundamentals）。
  Future<Fundamentals> fundamentals(String symbol,
      {bool refresh = false}) async {
    final clean = normalizeSymbol(symbol);
    if (!isAShareSymbol(clean)) {
      throw ProviderError('财务数据仅支持 A 股', 'local');
    }
    final stateKey = 'fundamentals:$clean';

    Fundamentals? cached;
    final raw = await store.getState(stateKey);
    if (raw != null) {
      try {
        final decoded = (jsonDecode(raw) as Map).cast<String, Object?>();
        final fetchedAt = DateTime.parse(decoded['fetched_at'] as String);
        cached = Fundamentals.fromJson(
            (decoded['data'] as Map).cast<String, Object?>());
        if (!refresh && now().difference(fetchedAt) < _fundamentalsTtl) {
          return cached;
        }
      } catch (_) {
        cached = null; // 缓存损坏按无缓存处理
      }
    }

    try {
      final data = await fundamentalsProvider.fundamentals(clean);
      await store.setState(
        stateKey,
        jsonEncode({
          'fetched_at': now().toIso8601String(),
          'data': data.toJson(),
        }),
      );
      return data;
    } catch (exc) {
      if (cached != null) return cached; // 远端不可用时回落到过期缓存
      rethrow;
    }
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
      case 'local':
        return '本地数据';
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
