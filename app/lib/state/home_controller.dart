/// 主界面状态控制器，数据流对齐 frontend/src/App.tsx：
/// 本地/缓存先渲染 → 后台强刷 → 静默更新；按面板隔离选中标的。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/market_repository.dart';
import '../data/symbol_utils.dart';
import '../data/sync_service.dart';
import '../logic/auto_drawing.dart';
import '../logic/calendar_window.dart';
import '../logic/market_panels.dart';
import '../models/models.dart';
import '../utils/format.dart';

/// 数据新鲜度状态（首页状态横条用）：
/// checking 启动检查中 → fresh 已到最近工作日 / updating 自动增量中 →
/// fresh 成功 / staleFailed 失败（可手动重试）
enum DataSyncState { checking, fresh, updating, staleFailed }

/// 本地日K是否已同步到最近一个工作日（周末取上周五）。
/// 不考虑法定节假日，判定从宽——只有比最近工作日还早才算不新。
bool isDataFresh(String? dataDate, DateTime now) {
  if (dataDate == null) return false;
  final parsed = DateTime.tryParse(dataDate);
  if (parsed == null) return false;
  var workday = DateTime(now.year, now.month, now.day);
  while (workday.weekday > DateTime.friday) {
    workday = workday.subtract(const Duration(days: 1));
  }
  return !DateTime(parsed.year, parsed.month, parsed.day).isBefore(workday);
}

class HomeController extends ChangeNotifier {
  final MarketRepository repository;

  HomeController(this.repository);

  List<WatchlistItem> watchlist = [];
  List<Quote> quotes = [];
  String selected = aShareConfig.fallback;
  String period = 'day';
  KlinePayload? kline;
  DataQuality? quoteQuality;
  DataQuality? klineQuality;
  String notice = '';
  bool loading = false;
  List<SymbolItem> searchResults = [];
  String query = '';

  /// 全市场后台同步状态（null 表示未在同步）
  SyncProgress? syncProgress;
  bool syncFailed = false;
  DateTime? _syncKlineStartAt;
  StreamSubscription<SyncProgress>? _syncSubscription;

  /// 数据新鲜度状态机（首页状态横条用）
  DataSyncState dataSyncState = DataSyncState.checking;

  /// 本地全市场日K最新交易日（YYYY-MM-DD，null = 尚无数据/未加载）
  String? dataDate;
  bool _incrementRunning = false;

  int _quotesRequestId = 0;
  int _detailRequestId = 0;
  int _searchRequestId = 0;
  bool _disposed = false;

  MarketConfig get activeConfig => aShareConfig;

  /// 当前标的是否已在自选里（八档局点进来的通常不在）
  bool get selectedInWatchlist =>
      watchlist.any((item) => item.symbol == selected);

  Quote? get selectedQuote {
    for (final quote in quotes) {
      if (quote.symbol == selected) return quote;
    }
    return null;
  }

  KlinePayload? get displayKline => sliceDailyPayloadByCalendarDays(
        kline,
        activeConfig.windowDays,
        mode: activeConfig.windowMode,
      );

  AutoDrawing? get autoDrawing {
    final display = displayKline;
    if (display == null || display.period != 'day') return null;
    return computeAutoDrawing(
      display.bars,
      windowSize: activeConfig.windowDays,
      levelStep: activeConfig.lineStep,
      extendLevelsBeyond100: activeConfig.extendLevelsBeyond100,
    );
  }

  KlineBar? get latestBar {
    final bars = displayKline?.bars;
    return bars == null || bars.isEmpty ? null : bars.last;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _syncSubscription?.cancel();
    super.dispose();
  }

  Future<void> bootstrap() async {
    await loadWatchlist();
    await Future.wait([
      loadQuotes(refresh: false),
      loadDetail(refresh: false, clearBeforeLoad: true),
    ]);
    _notify();
    // 后台强刷
    unawaited(_backgroundRefresh());
    // 全市场数据后台同步（首次全量或每日增量），不阻塞界面
    unawaited(startBackgroundSync());
  }

  /// 未初始化则跑全量同步（断点续传）；已初始化则检查数据新鲜度，
  /// 落后最近工作日时自动跑每日增量，状态经 dataSyncState 暴露给首页横条
  Future<void> startBackgroundSync() async {
    dataSyncState = DataSyncState.checking;
    _notify();
    if (!await repository.sync.isInitialized()) {
      _runInitialSync();
      return;
    }
    dataDate = await repository.sync.latestDataDate();
    if (isDataFresh(dataDate, DateTime.now())) {
      dataSyncState = DataSyncState.fresh;
      _notify();
      return;
    }
    await runDailyIncrement();
  }

  /// 跑一次每日增量（启动检查不新时自动触发；stale_failed 横条重试也走这里）。
  /// 成功即视为 fresh：节假日休市时快照仍是上一交易日，属正常，不再报落后。
  Future<void> runDailyIncrement() async {
    if (_incrementRunning) return;
    _incrementRunning = true;
    dataSyncState = DataSyncState.updating;
    _notify();
    try {
      await repository.sync.runDailyIncrement();
      dataDate = await repository.sync.latestDataDate();
      dataSyncState = DataSyncState.fresh;
    } catch (_) {
      dataSyncState = DataSyncState.staleFailed;
    } finally {
      _incrementRunning = false;
    }
    _notify();
  }

  /// 全量初始化完成后的收尾：记录数据日期并置 fresh
  Future<void> _markSyncedNow() async {
    dataDate = await repository.sync.latestDataDate();
    dataSyncState = DataSyncState.fresh;
    _notify();
  }

  void _runInitialSync() {
    syncFailed = false;
    _syncKlineStartAt = null;
    _syncSubscription?.cancel();
    _syncSubscription = repository.sync.runInitialSync().listen(
      (progress) {
        if (progress.phase == SyncPhase.klines) {
          _syncKlineStartAt ??= DateTime.now();
        }
        if (progress.phase == SyncPhase.done) {
          syncProgress = null;
          // 全量数据就位：状态横条转为 fresh
          unawaited(_markSyncedNow());
        } else {
          syncProgress = progress;
        }
        _notify();
      },
      onError: (Object exc) {
        syncFailed = true;
        syncProgress = null;
        _notify();
      },
    );
  }

  /// 顶部同步条的重试入口
  void retrySync() => _runInitialSync();

  /// 预计剩余时间文案（同步条用）
  String get syncEtaText {
    final progress = syncProgress;
    final startAt = _syncKlineStartAt;
    if (progress == null ||
        progress.phase != SyncPhase.klines ||
        startAt == null ||
        progress.klineDone < 20) {
      return '';
    }
    final elapsed = DateTime.now().difference(startAt).inSeconds;
    if (elapsed <= 0) return '';
    final rate = progress.klineDone / elapsed;
    if (rate <= 0) return '';
    final remaining =
        ((progress.klineTotal - progress.klineDone) / rate).round();
    if (remaining >= 60) return '，剩约 ${(remaining / 60).ceil()} 分钟';
    return '，剩约 $remaining 秒';
  }

  Future<void> _backgroundRefresh() async {
    try {
      await Future.wait([
        loadQuotes(refresh: true),
        loadDetail(refresh: true, clearBeforeLoad: false),
      ]);
    } catch (exc) {
      _setNotice(normalizeError(exc));
    }
  }

  Future<void> loadWatchlist() async {
    watchlist = await repository.listWatchlist();
    _fillSelected();
    _notify();
  }

  /// 选中标的失效（被删/首次启动）时落到自选首项，再退到内置标的
  void _fillSelected() {
    if (watchlist.any((item) => item.symbol == selected)) return;
    selected = watchlist.isNotEmpty
        ? watchlist.first.symbol
        : aShareConfig.fallback;
  }

  List<String> get _quoteTargets {
    final symbols = watchlist.map((item) => item.symbol).toList();
    // 非自选股（如八档局点击进来的）也拉行情，保证名称/现价可显示
    if (selected.isNotEmpty && !symbols.contains(selected)) {
      symbols.add(selected);
    }
    return symbols;
  }

  Future<void> loadQuotes({required bool refresh}) async {
    final targets = _quoteTargets;
    if (targets.isEmpty) return;
    final requestId = ++_quotesRequestId;
    try {
      final result = await repository.realtimeQuotes(targets, refresh: refresh);
      if (requestId != _quotesRequestId) return;
      quotes = result.quotes;
      quoteQuality = result.quality;
      unawaited(repository.rememberQuoteNames(result.quotes));
      if (result.quality.fallback || result.quality.stale) {
        notice = result.quality.message.isNotEmpty
            ? result.quality.message
            : qualityText(result.quality);
      }
      _notify();
    } catch (exc) {
      if (requestId != _quotesRequestId) return;
      _setNotice(normalizeError(exc));
    }
  }

  Future<void> loadDetail({
    required bool refresh,
    required bool clearBeforeLoad,
  }) async {
    final symbol = selected;
    if (symbol.isEmpty) return;
    final requestId = ++_detailRequestId;
    if (clearBeforeLoad) {
      kline = null;
      klineQuality = null;
      _notify();
    }
    try {
      final result = await repository.kline(
        symbol,
        period,
        refresh: refresh,
        limit: _periodLimit(period),
      );
      if (requestId != _detailRequestId) return;
      kline = result.payload;
      klineQuality = result.quality;
      _notify();
    } catch (exc) {
      if (requestId != _detailRequestId) return;
      _setNotice(normalizeError(exc));
    }
  }

  /// 各周期的展示根数：日 K 按面板窗口，周/月 K 固定窗口画近 2 年/5 年
  int _periodLimit(String period) {
    switch (period) {
      case 'day':
        return activeConfig.dayLimit;
      case 'week':
        return 104;
      case 'month':
        return 60;
    }
    return 1000;
  }

  void setPeriod(String next) {
    if (next == period) return;
    period = next;
    _notify();
    unawaited(loadDetail(refresh: false, clearBeforeLoad: true)
        .then((_) => loadDetail(refresh: true, clearBeforeLoad: false)));
  }

  void selectSymbol(String symbol, {bool resetPeriod = true}) {
    selected = symbol;
    if (resetPeriod) period = 'day';
    _notify();
    unawaited(loadDetail(refresh: false, clearBeforeLoad: true)
        .then((_) => loadDetail(refresh: true, clearBeforeLoad: false)));
    unawaited(loadQuotes(refresh: false));
  }

  Future<void> addSymbol(String symbol) async {
    loading = true;
    _notify();
    try {
      await repository.rememberQuoteNames(quotes);
      await repository.addWatchlist(symbol, aShareGroup);
      query = '';
      searchResults = [];
      await loadWatchlist();
      selectSymbol(symbol);
      unawaited(loadQuotes(refresh: true));
      } catch (exc) {
      _setNotice(normalizeError(exc));
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> removeSymbol(String symbol) async {
    loading = true;
    _notify();
    try {
      await repository.removeWatchlist(symbol);
      quotes = quotes.where((quote) => quote.symbol != symbol).toList();
      await loadWatchlist();
      if (selected == symbol || !watchlist.any((i) => i.symbol == selected)) {
        selectSymbol(watchlist.isNotEmpty
            ? watchlist.first.symbol
            : aShareConfig.fallback);
      }
      } catch (exc) {
      _setNotice(normalizeError(exc));
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> refreshAll() async {
    loading = true;
    notice = '';
    _notify();
    try {
      await Future.wait([
        loadQuotes(refresh: true),
        loadDetail(refresh: true, clearBeforeLoad: false),
      ]);
      } catch (exc) {
      _setNotice(normalizeError(exc));
    } finally {
      loading = false;
      _notify();
    }
  }

  Future<void> search(String next) async {
    query = next;
    _notify();
    final clean = next.trim();
    if (clean.isEmpty) {
      searchResults = [];
      _notify();
      return;
    }
    final requestId = ++_searchRequestId;
    // 全量沪深清单已由 sync_service 同步到本地，搜索只查本地表
    final results = await repository.searchSymbols(clean, limit: 8);
    if (requestId != _searchRequestId) return;
    searchResults =
        results.where((item) => isAShareSymbol(item.symbol)).toList();
    _notify();
  }

  void clearNotice() {
    notice = '';
    _notify();
  }

  void _setNotice(String message) {
    notice = message;
    _notify();
  }
}
