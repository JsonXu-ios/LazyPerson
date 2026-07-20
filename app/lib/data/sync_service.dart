/// 沪深全市场数据同步：首次全量初始化（可断点续传）、每日增量、90 天裁剪。
library;

import 'dart:async';

import 'package:lpinyin/lpinyin.dart';

import '../models/models.dart';
import 'local_store.dart';
import 'provider_error.dart';
import 'providers/eastmoney_provider.dart';
import 'providers/tencent_provider.dart';

enum SyncPhase { idle, listing, klines, pruning, done }

class SyncProgress {
  final SyncPhase phase;
  final int listLoaded;
  final int listTotal;
  final int klineDone;
  final int klineTotal;
  final int errorCount;
  final String currentSymbol;

  const SyncProgress({
    this.phase = SyncPhase.idle,
    this.listLoaded = 0,
    this.listTotal = 0,
    this.klineDone = 0,
    this.klineTotal = 0,
    this.errorCount = 0,
    this.currentSymbol = '',
  });

  /// 0.0 ~ 1.0，清单占 5%，日 K 占 95%
  double get ratio {
    final listRatio = listTotal > 0 ? listLoaded / listTotal : 0.0;
    final klineRatio = klineTotal > 0 ? klineDone / klineTotal : 0.0;
    switch (phase) {
      case SyncPhase.idle:
        return 0;
      case SyncPhase.listing:
        return listRatio * 0.05;
      case SyncPhase.klines:
        return 0.05 + klineRatio * 0.95;
      case SyncPhase.pruning:
      case SyncPhase.done:
        return 1;
    }
  }
}

class SyncService {
  static const retentionDays = 90;

  /// 裁剪留 5 天缓冲，避免边界日在窗口切片前被删掉
  static const _pruneBufferDays = 5;
  static const _initializedKey = 'initial_sync_done';

  final LocalStore store;
  final TencentProvider tencent;
  final EastmoneyProvider eastmoney;
  final int concurrency;
  final DateTime Function() now;

  SyncService({
    required this.store,
    TencentProvider? tencent,
    EastmoneyProvider? eastmoney,
    this.concurrency = 8,
    DateTime Function()? now,
  })  : tencent = tencent ?? TencentProvider(),
        eastmoney = eastmoney ?? EastmoneyProvider(),
        now = now ?? DateTime.now;

  Future<bool> isInitialized() async =>
      await store.getState(_initializedKey) == '1';

  String get _today => now().toIso8601String().substring(0, 10);

  String get _rangeStart => now()
      .subtract(const Duration(days: retentionDays + _pruneBufferDays))
      .toIso8601String()
      .substring(0, 10);

  /// 首次全量初始化（或手动全量校准）。可重入：已完成的股票自动跳过。
  Stream<SyncProgress> runInitialSync() async* {
    var progress = const SyncProgress(phase: SyncPhase.listing);
    yield progress;

    // 第一段：全市场清单 + 当日快照
    final controller = StreamController<SyncProgress>();
    final snapshotFuture = eastmoney.fullMarketSnapshot(
      onProgress: (loaded, total) {
        controller.add(SyncProgress(
            phase: SyncPhase.listing, listLoaded: loaded, listTotal: total));
      },
    ).whenComplete(controller.close);
    yield* controller.stream;
    final snapshot = await snapshotFuture;
    if (snapshot.isEmpty) {
      throw const ProviderError('全市场清单拉取失败', EastmoneyProvider.source);
    }
    await _writeSnapshot(snapshot);

    // 第二段：逐只同步 90 天日 K（并发 + 断点续传，自选优先）
    final today = _today;
    final synced = await store.syncedDates();
    final watchSymbols =
        (await store.listWatchlist()).map((item) => item.symbol).toSet();
    final pending = snapshot
        .map((quote) => quote.symbol)
        .where((symbol) => (synced[symbol] ?? '') != today)
        .toList()
      ..sort((a, b) {
        final aWatch = watchSymbols.contains(a) ? 0 : 1;
        final bWatch = watchSymbols.contains(b) ? 0 : 1;
        if (aWatch != bWatch) return aWatch - bWatch;
        return a.compareTo(b);
      });

    final total = pending.length;
    var done = 0;
    var errors = 0;

    final progressController = StreamController<SyncProgress>();
    Future<void> worker(Iterator<String> queue) async {
      while (true) {
        String symbol;
        // Iterator 在单 isolate 事件循环内串行推进，无并发竞争
        if (!queue.moveNext()) return;
        symbol = queue.current;
        try {
          await _syncDailyKline(symbol);
          await store.setSyncState(symbol, today, 'done');
        } catch (_) {
          errors += 1;
          await store.setSyncState(symbol, '', 'error');
        }
        done += 1;
        if (!progressController.isClosed) {
          progressController.add(SyncProgress(
            phase: SyncPhase.klines,
            listLoaded: snapshot.length,
            listTotal: snapshot.length,
            klineDone: done,
            klineTotal: total,
            errorCount: errors,
            currentSymbol: symbol,
          ));
        }
      }
    }

    final iterator = pending.iterator;
    final workers = List.generate(concurrency, (_) => worker(iterator));
    Future.wait(workers).whenComplete(progressController.close);
    yield* progressController.stream;

    yield SyncProgress(
      phase: SyncPhase.pruning,
      listLoaded: snapshot.length,
      listTotal: snapshot.length,
      klineDone: done,
      klineTotal: total,
      errorCount: errors,
    );
    await store.pruneDailyBars(_rangeStart);
    await store.setState(_initializedKey, '1');
    yield SyncProgress(
      phase: SyncPhase.done,
      listLoaded: snapshot.length,
      listTotal: snapshot.length,
      klineDone: done,
      klineTotal: total,
      errorCount: errors,
    );
  }

  /// 每日增量：55 页快照把当天 bar 批量写入全市场，然后裁剪
  Future<void> runDailyIncrement() async {
    final snapshot = await eastmoney.fullMarketSnapshot();
    if (snapshot.isEmpty) return;
    await _writeSnapshot(snapshot);
    await store.pruneDailyBars(_rangeStart);
  }

  Future<void> _writeSnapshot(List<Quote> snapshot) async {
    final items = snapshot
        .map((quote) => SymbolItem(
              symbol: quote.symbol,
              market: quote.market,
              name: quote.name,
              pinyinAbbr: quote.name.isEmpty
                  ? ''
                  : PinyinHelper.getShortPinyin(quote.name).toUpperCase(),
            ))
        .toList();
    await store.upsertSymbols(items);

    // 当天 bar：交易日快照的 OHLCV upsert 进 daily_bars
    final tradeDate = _snapshotTradeDate(snapshot);
    if (tradeDate == null) return;
    for (var offset = 0; offset < snapshot.length; offset += 500) {
      final chunk = snapshot.sublist(
          offset,
          offset + 500 > snapshot.length ? snapshot.length : offset + 500);
      final batchable = <String, KlineBar>{};
      for (final quote in chunk) {
        if (quote.price == null || quote.open == null) continue;
        batchable[quote.symbol] = KlineBar(
          time: tradeDate,
          open: quote.open,
          high: quote.high,
          low: quote.low,
          close: quote.price,
          volume: quote.volume,
          amount: quote.amount,
          pctChg: quote.pctChg,
          turnover: quote.turnover,
        );
      }
      for (final entry in batchable.entries) {
        await store.upsertDailyBars(entry.key, [entry.value]);
      }
    }
  }

  /// 从快照 trade_time 推断交易日；非交易时段/周末快照仍带最近交易日时间戳
  String? _snapshotTradeDate(List<Quote> snapshot) {
    for (final quote in snapshot) {
      final time = quote.tradeTime;
      if (time != null && time.length >= 10) return time.substring(0, 10);
    }
    return null;
  }

  /// 单只股票 90 天日 K：腾讯为主、东财兜底，整段替换本地数据
  Future<void> _syncDailyKline(String symbol) async {
    List<KlineBar> bars;
    try {
      bars = await tencent.kline(symbol, 'day',
          start: _rangeStart, end: _today, adjust: 'qfq');
    } catch (_) {
      bars = await eastmoney.kline(symbol, 'day',
          start: _rangeStart, end: _today, adjust: 'qfq');
    }
    if (bars.isEmpty) {
      throw ProviderError('empty kline for $symbol', TencentProvider.source);
    }
    await store.upsertDailyBars(symbol, bars);
  }

  /// 单只即时补齐（查看某只股票时本地数据落后使用）
  Future<void> refreshSymbol(String symbol) async {
    await _syncDailyKline(symbol);
    await store.setSyncState(symbol, _today, 'done');
  }
}
