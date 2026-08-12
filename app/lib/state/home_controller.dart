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

/// 全市场数据流水线的阶段（自选页状态条用）。依赖顺序固定：
///
///   checking（读本地状态）
///     ├─ 未初始化 → initializing（清单 → 逐只日K → 裁剪）
///     └─ 已初始化 → 数据不新鲜 → incrementing（一次快照批量补当日 bar）
///   → ready（八档局此时才允许扫描）
///
/// ready 之后还有两个用户显式触发的分支：repairing（补齐失败/缺日K的股票）
/// 与 fullRefreshing（强制全量刷新，等于清状态后重跑 initializing）。
/// 任一分支失败 → failed，带 syncError 文案与重试入口。
enum SyncStage {
  checking,
  initializing,
  incrementing,
  repairing,
  fullRefreshing,
  ready,
  failed,
}

/// 阶段的用户可见文案（失败/进度细节由控制器另外拼）
const syncStageLabels = <SyncStage, String>{
  SyncStage.checking: '正在检查本地数据…',
  SyncStage.initializing: '正在初始化全市场数据…',
  SyncStage.incrementing: '正在更新全市场数据…',
  SyncStage.repairing: '正在补齐缺失数据…',
  SyncStage.fullRefreshing: '正在强制全量刷新…',
  SyncStage.ready: '数据已就绪',
  SyncStage.failed: '数据更新失败',
};

/// 本地日K是否已同步到最近一个工作日（周末取上周五）。
/// 不考虑法定节假日，判定从宽——只有比最近工作日还早才算不新。
/// 同步时刻文案：当天只显示 HH:mm，跨天带上 MM-DD
String formatSyncTime(DateTime at, {DateTime? now}) {
  final today = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  final clock = '${two(at.hour)}:${two(at.minute)}';
  final sameDay =
      at.year == today.year && at.month == today.month && at.day == today.day;
  return sameDay ? clock : '${two(at.month)}-${two(at.day)} $clock';
}

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

  /// 当前行情是否来自本地缓存（无网络降级），界面据此提示
  bool offlineQuotesInUse = false;
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
  DateTime? _syncKlineStartAt;
  StreamSubscription<SyncProgress>? _syncSubscription;

  /// 数据流水线状态机（自选页状态条用）
  SyncStage syncStage = SyncStage.checking;

  /// 失败时的具体原因（stage == failed 时非空）
  String syncError = '';

  /// 本地全市场日K最新交易日（YYYY-MM-DD，null = 尚无数据/未加载）
  String? dataDate;

  /// 上次同步完成时刻（数据日期只到天，这里补出具体几点几分）
  DateTime? lastSyncAt;

  /// 待补齐的股票数（初始同步失败的 + 一根日K都没有的），ready 后统计
  int pendingRepairCount = 0;

  /// 数据新鲜度：本地日K已更新到最新交易日的股票数
  int freshCount = 0;

  /// 全市场清单总数（新鲜度的分母）
  int totalSymbolCount = 0;

  /// 尚未更新到最新交易日的股票数
  int get staleCount =>
      totalSymbolCount > freshCount ? totalSymbolCount - freshCount : 0;

  /// 补齐进度
  int repairDone = 0;
  int repairTotal = 0;

  /// 补齐结果提示
  String repairNote = '';

  /// 自选股所属板块（含今日热点标记），列表加载时批量取一次，当天复用缓存
  Map<String, StockSectors> watchlistSectors = {};

  bool _incrementRunning = false;
  int _pipelineRunId = 0;

  /// 流水线真正有活儿在跑（不能只看 stage：初始 stage 是 checking，
  /// 但那时还没人在跑，按钮不该被禁）
  bool _busy = false;

  /// 同步流水线是否在忙（忙时禁掉重复触发的按钮）
  bool get syncBusy => _busy;

  /// 失败状态（旧 UI 的 syncFailed）
  bool get syncFailed => syncStage == SyncStage.failed;

  /// 状态条主文案：阶段标签 + 进度/数据日期细节
  String get syncText {
    switch (syncStage) {
      case SyncStage.failed:
        return syncError.isEmpty ? '数据更新失败，点按重试' : syncError;
      case SyncStage.ready:
        if (dataDate == null) return '本地暂无数据';
        final at = lastSyncAt;
        return at == null
            ? '数据已同步至 $dataDate'
            : '数据已同步至 $dataDate · ${formatSyncTime(at)}更新';
      case SyncStage.repairing:
        return '正在补齐缺失数据 $repairDone/$repairTotal';
      case SyncStage.initializing:
      case SyncStage.fullRefreshing:
        return _initialSyncText;
      default:
        return syncStageLabels[syncStage] ?? '';
    }
  }

  String get _initialSyncText {
    final progress = syncProgress;
    final prefix = syncStage == SyncStage.fullRefreshing ? '强制全量刷新' : '初始化';
    if (progress == null) return '$prefix：正在准备…';
    switch (progress.phase) {
      case SyncPhase.listing:
        return '$prefix：获取沪深清单 (${progress.listLoaded}/${progress.listTotal == 0 ? '…' : progress.listTotal})';
      case SyncPhase.klines:
        return '$prefix：同步日线 ${progress.klineDone}/${progress.klineTotal} 只$syncEtaText';
      case SyncPhase.pruning:
        return '$prefix：正在整理本地数据…';
      default:
        return '$prefix：正在准备…';
    }
  }

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
    lastSyncAt = await repository.sync.lastSyncAt();
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

  /// 数据流水线入口，按固定依赖顺序推进（见 [SyncStage] 注释）：
  /// 未初始化 → 全量初始化；已初始化但数据落后 → 每日增量；否则直接 ready。
  /// 八档局扫描依赖这条流水线走到 ready。
  Future<void> startBackgroundSync() async {
    if (_busy) return;
    _busy = true;
    syncStage = SyncStage.checking;
    syncError = '';
    _notify();
    if (!await repository.sync.isInitialized()) {
      _runInitialSync(fullRefresh: false);
      return;
    }
    dataDate = await repository.sync.latestDataDate();
    if (isDataFresh(dataDate, DateTime.now())) {
      await _markReady();
      return;
    }
    await runDailyIncrement();
  }

  /// 跑一次每日增量（启动检查不新时自动触发；失败横条重试也走这里）。
  /// 成功即视为 ready：节假日休市时快照仍是上一交易日，属正常，不再报落后。
  Future<void> runDailyIncrement() async {
    if (_incrementRunning) return;
    _incrementRunning = true;
    _busy = true;
    syncStage = SyncStage.incrementing;
    syncError = '';
    _notify();
    try {
      await repository.sync.runDailyIncrement();
      await _markReady();
    } catch (exc) {
      _fail('数据更新失败：${normalizeError(exc)}');
    } finally {
      _incrementRunning = false;
    }
  }

  /// 流水线收尾：记录数据日期、统计待补齐数量并置 ready
  Future<void> _markReady() async {
    await repository.sync.markSynced();
    dataDate = await repository.sync.latestDataDate();
    lastSyncAt = await repository.sync.lastSyncAt();
    syncStage = SyncStage.ready;
    syncError = '';
    _busy = false;
    _notify();
    await refreshRepairCount();
  }

  void _fail(String message) {
    syncStage = SyncStage.failed;
    syncError = message;
    _busy = false;
    _notify();
  }

  /// 统计"补齐数据"入口要处理多少只（初始同步失败的 + 缺日K的），
  /// 同时刷新数据新鲜度（已最新 X / 待更新 Y）
  Future<void> refreshRepairCount() async {
    try {
      pendingRepairCount =
          (await repository.sync.pendingRepairSymbols()).length;
    } catch (_) {
      pendingRepairCount = 0;
    }
    try {
      final counts = await repository.sync.freshness();
      freshCount = counts.fresh;
      totalSymbolCount = counts.total;
    } catch (_) {
      freshCount = 0;
      totalSymbolCount = 0;
    }
    _notify();
  }

  void _runInitialSync({required bool fullRefresh}) {
    final runId = ++_pipelineRunId;
    _busy = true;
    syncStage =
        fullRefresh ? SyncStage.fullRefreshing : SyncStage.initializing;
    syncError = '';
    _syncKlineStartAt = null;
    _syncSubscription?.cancel();
    _notify();
    _syncSubscription = repository.sync.runInitialSync().listen(
      (progress) {
        if (runId != _pipelineRunId) return;
        if (progress.phase == SyncPhase.klines) {
          _syncKlineStartAt ??= DateTime.now();
        }
        if (progress.phase == SyncPhase.done) {
          syncProgress = null;
          unawaited(_markReady());
        } else {
          syncProgress = progress;
        }
        _notify();
      },
      onError: (Object exc) {
        if (runId != _pipelineRunId) return;
        syncProgress = null;
        _fail('全市场数据同步中断：${normalizeError(exc)}（已同步部分可用，点按重试）');
      },
    );
  }

  /// 状态条的重试入口：按当前阶段决定重跑哪一段（初始化 vs 增量）
  Future<void> retrySync() async {
    if (_busy) return;
    if (await repository.sync.isInitialized()) {
      await runDailyIncrement();
    } else {
      _runInitialSync(fullRefresh: false);
    }
  }

  /// 「补齐数据」：把初始同步失败的、缺日K的股票统一重拉一遍。
  /// 与八档局的 backfillMissing 同一套语义，失败的留到下次可再点。
  Future<void> repairData() async {
    if (_busy) return;
    final runId = ++_pipelineRunId;
    _busy = true;
    syncStage = SyncStage.repairing;
    syncError = '';
    repairNote = '';
    repairDone = 0;
    repairTotal = 0;
    _notify();
    try {
      final pending = await repository.sync.pendingRepairSymbols();
      repairTotal = pending.length;
      _notify();
      if (pending.isEmpty) {
        repairNote = '没有需要补齐的数据';
        await _markReady();
        return;
      }
      final failed = await repository.sync.repairSymbols(
        pending,
        shouldStop: () => runId != _pipelineRunId,
        onProgress: (done, total) {
          if (runId != _pipelineRunId) return;
          repairDone = done;
          repairTotal = total;
          if (done % 5 == 0 || done == total) _notify();
        },
      );
      if (runId != _pipelineRunId) return;
      repairNote = failed.isEmpty
          ? '已补齐 $repairTotal 只'
          : '补齐 ${repairTotal - failed.length}/$repairTotal 只，${failed.length} 只失败，可再点一次';
      await _markReady();
    } catch (exc) {
      if (runId != _pipelineRunId) return;
      _fail('补齐失败：${normalizeError(exc)}');
    }
  }

  /// 「强制全量刷新」：清掉初始化标记与逐只同步状态，重新拉全市场清单 +
  /// 每只 90 天日K覆盖本地。调用方负责二次确认。
  Future<void> forceFullRefresh() async {
    if (_busy) return;
    _busy = true;
    syncStage = SyncStage.checking;
    syncError = '';
    repairNote = '';
    _notify();
    try {
      await repository.sync.resetForFullRefresh();
    } catch (exc) {
      _fail('强制刷新准备失败：${normalizeError(exc)}');
      return;
    }
    _runInitialSync(fullRefresh: true);
  }

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
    unawaited(loadWatchlistSectors());
  }

  /// 自选股的行业/概念与今日热点标记：**列表加载时批量取一次**，渲染时只读
  /// 这份内存映射，绝不在 itemBuilder 里发请求。sectorsOfMany 内部按天缓存，
  /// 当天第二次进来全部命中缓存，零请求。
  Future<void> loadWatchlistSectors({bool refresh = false}) async {
    final symbols = [for (final item in watchlist) item.symbol];
    if (symbols.isEmpty) {
      watchlistSectors = {};
      _notify();
      return;
    }
    final pending = refresh
        ? symbols
        : [
            for (final symbol in symbols)
              if (!watchlistSectors.containsKey(symbol)) symbol,
          ];
    if (pending.isEmpty) return;
    try {
      final result = await repository.sectors.sectorsOfMany(pending);
      watchlistSectors = {...watchlistSectors, ...result};
      _notify();
    } catch (_) {
      // 板块只是行上的一个 tag，取不到就不显示，不打扰用户
    }
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
      offlineQuotesInUse = false;
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
      // 无网络/接口失败：退回本地日 K 的最新一根，列表仍有价格可看
      try {
        final offline = await repository.offlineQuotes(targets);
        if (requestId != _quotesRequestId) return;
        if (offline.isNotEmpty) {
          quotes = offline;
          offlineQuotesInUse = true;
          _setNotice('行情不可用，显示本地缓存价（${offline.first.tradeTime ?? ''}）');
          return;
        }
      } catch (_) {
        // 本地也没有就照常报错
      }
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
        loadWatchlistSectors(refresh: true),
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
