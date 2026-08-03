/// 八档局扫描状态控制器：全市场行情快照（东财，腾讯兜底）+
/// 本地 sqlite 已同步的 90 天日 K，流程语义对齐 backend/app/scanner.py。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/fundamentals_service.dart';
import '../data/market_repository.dart';
import '../logic/band_scanner.dart';
import '../models/models.dart';

enum BandScanStatus { idle, running, done, failed }

class BandScanController extends ChangeNotifier {
  /// 总市值下限（亿元），勾选“总市值>40亿”时生效
  static const marketCapMin = 40.0;

  /// v4: 命中行含 dividendRecent/profitOk 基本面标记，旧结果作废
  static const _stateKey = 'band_scan:last:v4';

  final MarketRepository repository;
  final DateTime Function() now;

  /// 基本面标记取数（分红/净利润），测试可注入假实现
  late final FundamentalsService fundamentals;

  BandScanController(this.repository,
      {DateTime Function()? nowFn, FundamentalsService? fundamentals})
      : now = nowFn ?? DateTime.now {
    this.fundamentals = fundamentals ??
        FundamentalsService(
          store: repository.store,
          provider: repository.fundamentalsProvider,
          nowFn: now,
        );
  }

  BandScanStatus status = BandScanStatus.idle;
  String stage = ''; // snapshot | kline | fundamentals | ''
  int total = 0;
  int done = 0;
  List<BandHit> hits = [];
  String? tradeDate;
  double? minMarketCap;
  String? error;

  /// 本地日K缺失/不足20根而未参与判定的股票数（数据完整性提示，非规则排除）
  int skippedNoData = 0;

  /// 同步状态：本地全市场日K的最新交易日（null = 尚无数据/未加载）
  String? dataDate;

  /// 是否已完成首次全量初始化
  bool? initialized;

  /// 手动刷新（每日增量）进行中
  bool refreshing = false;

  /// 扫描参数：总市值>40亿（默认勾选，取消则不过滤）
  bool capFilter = true;

  /// 展示层过滤：只看今日涨停（默认勾选，取消显示全部，无需重扫）
  bool limitUpFilter = true;

  /// 展示层过滤：「从高处来」的两种形态默认隐藏，勾选后并入列表（无需重扫）
  bool showFromTop = false;

  /// 展示层过滤：只看近一年有分红（含已公告的今年分红），默认关，无需重扫
  bool dividendFilter = false;

  /// 展示层过滤：只看净利润达标（归母净利≥0 且 Q1营收×40>总市值），默认关
  bool profitFilter = false;

  int activeGroup = 1;

  bool _disposed = false;
  int _runId = 0;
  bool _restored = false;

  bool get running => status == BandScanStatus.running;

  /// 展示层过滤后的命中（对齐 MoneyGrabPanel.tsx 的 visibleHits）
  List<BandHit> get visibleHits => hits
      .where((hit) =>
          (!limitUpFilter || hit.limitUp) &&
          (showFromTop || !hit.fromTop) &&
          (!dividendFilter || hit.dividendRecent) &&
          (!profitFilter || hit.profitOk))
      .toList();

  Map<int, int> get groupCounts {
    final counts = <int, int>{};
    for (final hit in visibleHits) {
      counts[hit.group] = (counts[hit.group] ?? 0) + 1;
    }
    return counts;
  }

  /// 当前档命中，组内按超出幅度(over)降序
  List<BandHit> get activeHits =>
      visibleHits.where((hit) => hit.group == activeGroup).toList()
        ..sort((a, b) => b.over.compareTo(a.over));

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _runId += 1;
    super.dispose();
  }

  void setActiveGroup(int group) {
    if (group == activeGroup) return;
    activeGroup = group;
    _notify();
  }

  void setCapFilter(bool value) {
    if (value == capFilter) return;
    capFilter = value;
    _notify();
  }

  void setLimitUpFilter(bool value) {
    if (value == limitUpFilter) return;
    limitUpFilter = value;
    _notify();
  }

  void setShowFromTop(bool value) {
    if (value == showFromTop) return;
    showFromTop = value;
    _notify();
  }

  void setDividendFilter(bool value) {
    if (value == dividendFilter) return;
    dividendFilter = value;
    _notify();
  }

  void setProfitFilter(bool value) {
    if (value == profitFilter) return;
    profitFilter = value;
    _notify();
  }

  String get _today => now().toIso8601String().substring(0, 10);

  /// 加载同步状态（初始化标记 + 本地数据最新交易日）
  Future<void> loadSyncStatus() async {
    initialized = await repository.sync.isInitialized();
    dataDate = await repository.sync.latestDataDate();
    _notify();
  }

  /// 手动刷新全A股：跑一次每日增量（55页快照批量写当日bar），并更新状态
  Future<void> refreshData() async {
    if (refreshing || running) return;
    if (initialized == false) {
      error = '请先在首页完成全市场初始化同步';
      _notify();
      return;
    }
    refreshing = true;
    error = null;
    _notify();
    try {
      await repository.sync.runDailyIncrement();
      dataDate = await repository.sync.latestDataDate();
    } catch (exc) {
      error = '刷新失败：$exc';
    } finally {
      refreshing = false;
      _notify();
    }
  }

  /// 恢复当日扫描结果（对齐 scanner.py::_load_persisted：隔日作废）
  Future<void> restore() async {
    if (_restored || status != BandScanStatus.idle) return;
    _restored = true;
    try {
      final raw = await repository.store.getState(_stateKey);
      if (raw == null) return;
      final data = (jsonDecode(raw) as Map).cast<String, Object?>();
      if (data['trade_date'] != _today) return;
      hits = [
        for (final row in (data['hits'] as List? ?? const []))
          BandHit.fromJson((row as Map).cast<String, Object?>()),
      ];
      total = (data['total'] as num?)?.toInt() ?? hits.length;
      skippedNoData = (data['skipped_no_data'] as num?)?.toInt() ?? 0;
      done = total;
      tradeDate = data['trade_date'] as String?;
      minMarketCap = (data['min_market_cap'] as num?)?.toDouble();
      capFilter = minMarketCap != null;
      status = BandScanStatus.done;
      _notify();
    } catch (_) {
      // 恢复失败按无结果处理
    }
  }

  Future<void> startScan() async {
    if (running) return;
    // 全市场日K未同步完成时本地数据残缺，扫描结果会漏股票（如刚安装的设备），直接拒绝
    if (!await repository.sync.isInitialized()) {
      status = BandScanStatus.failed;
      stage = '';
      error = '全市场日K尚未同步完成：请回到首页等待初始化同步结束后再扫描';
      _notify();
      return;
    }
    final runId = ++_runId;
    // 涨停是展示层过滤（每条命中带 limitUp 标记），扫描本身不过滤，勾选切换即时生效
    final capLimit = capFilter ? marketCapMin : null;
    status = BandScanStatus.running;
    stage = 'snapshot';
    total = 0;
    done = 0;
    hits = [];
    error = null;
    skippedNoData = 0;
    tradeDate = _today;
    minMarketCap = capLimit;
    _notify();
    try {
      await _run(runId, capLimit);
    } catch (exc) {
      if (runId != _runId) return;
      status = BandScanStatus.failed;
      stage = '';
      error = '$exc';
      _notify();
    }
  }

  Future<void> _run(int runId, double? capLimit) async {
    final quotes = await _fetchAllAQuotes();
    if (runId != _runId) return;

    // 候选过滤：沪深主板、非 ST、有最新价、（可选）市值下限
    final candidates = quotes
        .where((quote) =>
            eligibleSymbol(quote.symbol, quote.name) &&
            quote.price != null &&
            (capLimit == null ||
                (quote.marketCap != null && quote.marketCap! >= capLimit)))
        .toList();
    total = candidates.length;
    stage = 'kline';
    _notify();

    final today = now();
    final collected = <BandHit>[];
    for (final quote in candidates) {
      if (runId != _runId) return;
      final bars = await repository.store.getDailyBars(quote.symbol);
      if (validScanBars(bars).length < scanMinBars) {
        // 本地日K缺失/不足：不是规则排除，单独计数并在界面提示
        skippedNoData += 1;
      } else {
        final row = evaluateStock(quote.symbol, quote.name, quote.price, bars,
            today: today);
        if (row != null) {
          collected.add(
              row.copyWith(limitUp: isLimitUp(quote.price, quote.preClose)));
        }
      }
      done += 1;
      if (done % 50 == 0) {
        hits = List.of(collected);
        _notify();
      }
    }

    // 基本面标记（分红/净利润）：只查命中股（约一两百只），缓存3天；
    // 单只取数失败不影响扫描结果，标记保持默认 false（对齐 scanner.py fundamentals 阶段）
    stage = 'fundamentals';
    hits = List.of(collected);
    _notify();
    final caps = {
      for (final quote in candidates) quote.symbol: quote.marketCap,
    };
    for (var i = 0; i < collected.length; i++) {
      if (runId != _runId) return;
      final hit = collected[i];
      try {
        final marks = await fundamentals.marksFor(hit.symbol, caps[hit.symbol]);
        collected[i] = hit.copyWith(
          dividendRecent: marks.dividendRecent,
          profitOk: marks.profitOk,
        );
      } catch (_) {
        // 取数失败保持默认 false
      }
    }

    collected.sort((a, b) {
      final byGroup = a.group.compareTo(b.group);
      if (byGroup != 0) return byGroup;
      return b.over.compareTo(a.over);
    });
    hits = collected;
    status = BandScanStatus.done;
    stage = '';
    _notify();
    await _persist();
  }

  Future<void> _persist() async {
    await repository.store.setState(
      _stateKey,
      jsonEncode({
        'trade_date': tradeDate,
        'min_market_cap': minMarketCap,
        'total': total,
        'skipped_no_data': skippedNoData,
        'finished_at': now().toIso8601String(),
        'hits': [for (final hit in hits) hit.toJson()],
      }),
    );
  }

  /// 全市场A股快照：东财 clist（内置主备域名）优先，失败或残缺时
  /// 用本地清单分批走腾讯行情兜底（对齐 scanner.py::_fetch_all_a_quotes）。
  Future<List<Quote>> _fetchAllAQuotes() async {
    final errors = <String>[];
    try {
      final snapshot = await repository.sync.eastmoney.fullMarketSnapshot();
      if (snapshot.isNotEmpty) return snapshot;
      errors.add('eastmoney:empty');
    } catch (exc) {
      errors.add('eastmoney:$exc');
    }

    final symbols = await repository.store.mainBoardASymbols();
    if (symbols.isEmpty) {
      throw StateError(
          '行情快照拉取失败且本地清单为空（${errors.join('; ')}），请等待全市场同步完成后重试');
    }
    final quotes = <Quote>[];
    for (var offset = 0; offset < symbols.length; offset += 80) {
      final batch = symbols.sublist(
          offset, offset + 80 > symbols.length ? symbols.length : offset + 80);
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          quotes.addAll(await repository.tencent.realtimeQuotes(batch));
          break;
        } catch (_) {
          if (attempt == 1) break; // 静默丢批，最后统一校验完整度
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    }
    if (quotes.length < symbols.length * 0.5) {
      throw StateError(
          '腾讯行情兜底不完整：${quotes.length}/${symbols.length}（${errors.join('; ')}）');
    }
    return quotes;
  }
}
