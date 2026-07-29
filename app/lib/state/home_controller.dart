/// 主界面状态控制器，数据流对齐 frontend/src/App.tsx：
/// 本地/缓存先渲染 → 后台强刷 → 静默更新；按面板隔离选中标的。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/market_repository.dart';
import '../data/sync_service.dart';
import '../logic/auto_drawing.dart';
import '../logic/calendar_window.dart';
import '../logic/market_panels.dart';
import '../models/models.dart';
import '../utils/format.dart';

const _lineColorsKey = 'lazy-person:auto-line-colors:v3';

class HomeController extends ChangeNotifier {
  final MarketRepository repository;

  HomeController(this.repository);

  List<WatchlistItem> watchlist = [];
  List<Quote> quotes = [];
  PanelKey activePanel = PanelKey.aShare;
  final Map<PanelKey, String> selectedByPanel = {
    for (final panel in marketPanels) panel.key: panel.fallback,
  };
  String period = 'day';
  KlinePayload? kline;
  DataQuality? quoteQuality;
  DataQuality? klineQuality;
  String notice = '';
  bool loading = false;
  Map<String, String> lineColors = Map.of(defaultLineColors);
  List<SymbolItem> searchResults = [];
  String query = '';

  /// 全市场后台同步状态（null 表示未在同步）
  SyncProgress? syncProgress;
  bool syncFailed = false;
  DateTime? _syncKlineStartAt;
  StreamSubscription<SyncProgress>? _syncSubscription;

  int _quotesRequestId = 0;
  int _detailRequestId = 0;
  int _searchRequestId = 0;
  bool _disposed = false;

  MarketPanelConfig get activeConfig => panelConfig(activePanel);

  String get selected => selectedByPanel[activePanel] ?? '';

  List<WatchlistItem> get panelWatchlist => watchlist
      .where((item) =>
          panelForAsset(
              symbol: item.symbol,
              market: item.market,
              groupName: item.groupName,
              note: item.note) ==
          activePanel)
      .toList();

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
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lineColorsKey);
    if (raw != null) {
      try {
        final saved = (jsonDecode(raw) as Map).cast<String, Object?>();
        lineColors = {
          ...defaultLineColors,
          for (final entry in saved.entries) entry.key: '${entry.value}',
        };
      } catch (_) {
        lineColors = Map.of(defaultLineColors);
      }
    }
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

  /// 未初始化则跑全量同步（断点续传），已初始化则跑每日增量
  Future<void> startBackgroundSync() async {
    if (await repository.sync.isInitialized()) {
      try {
        await repository.sync.runDailyIncrement();
      } catch (_) {
        // 增量失败静默，下次启动或手动刷新会再试
      }
      return;
    }
    _runInitialSync();
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
          // 全量数据就位后刷新信号
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
    _fillSelectedPanels();
    _notify();
  }

  void _fillSelectedPanels() {
    for (final panel in marketPanels) {
      final rows = watchlist.where((item) =>
          panelForAsset(
              symbol: item.symbol,
              market: item.market,
              groupName: item.groupName,
              note: item.note) ==
          panel.key);
      final current = selectedByPanel[panel.key];
      final hasCurrent = rows.any((item) => item.symbol == current);
      selectedByPanel[panel.key] = hasCurrent
          ? current!
          : (rows.isNotEmpty ? rows.first.symbol : panel.fallback);
    }
  }

  List<String> get _quoteTargets {
    final symbols = panelWatchlist.map((item) => item.symbol).toList();
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

  void setPanel(PanelKey panel) {
    if (panel == activePanel) return;
    activePanel = panel;
    period = 'day';
    quotes = [];
    kline = null;
    quoteQuality = null;
    klineQuality = null;
    query = '';
    searchResults = [];
    _notify();
    unawaited(loadQuotes(refresh: false).then((_) => loadQuotes(refresh: true)));
    unawaited(loadDetail(refresh: false, clearBeforeLoad: true)
        .then((_) => loadDetail(refresh: true, clearBeforeLoad: false)));
  }

  void setPeriod(String next) {
    if (next == period) return;
    period = next;
    _notify();
    unawaited(loadDetail(refresh: false, clearBeforeLoad: true)
        .then((_) => loadDetail(refresh: true, clearBeforeLoad: false)));
  }

  void selectSymbol(String symbol, {bool resetPeriod = true}) {
    selectedByPanel[activePanel] = symbol;
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
      await repository.addWatchlist(symbol, panelGroupName(activePanel));
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
      if (selected == symbol || !panelWatchlist.any((i) => i.symbol == selected)) {
        final next = panelWatchlist.isNotEmpty
            ? panelWatchlist.first.symbol
            : activeConfig.fallback;
        selectSymbol(next);
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
    // A 股面板查本地全量表；其他面板本地内置 + Yahoo 在线搜索
    var results = await repository.searchSymbols(clean, limit: 8);
    if (activePanel != PanelKey.aShare && results.length < 8) {
      try {
        final online = await repository.yahoo.searchSymbols(clean, limit: 8);
        final seen = results.map((item) => item.symbol).toSet();
        results = [
          ...results,
          ...online.where((item) => !seen.contains(item.symbol)),
        ];
      } catch (_) {
        // 在线搜索失败时只用本地结果
      }
    }
    if (requestId != _searchRequestId) return;
    searchResults = results
        .where((item) =>
            panelForAsset(symbol: item.symbol, market: item.market) ==
            activePanel)
        .toList();
    _notify();
  }

  Future<void> updateLineColor(String label, String colorHex) async {
    lineColors = {...lineColors, label: colorHex};
    _notify();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lineColorsKey, jsonEncode(lineColors));
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
