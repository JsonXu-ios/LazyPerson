/// 八档局扫描状态控制器：全市场行情快照（东财，腾讯兜底）+
/// 本地 sqlite 已同步的 90 天日 K，流程语义对齐 backend/app/scanner.py。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/fundamentals_service.dart';
import '../data/lon_check_service.dart';
import '../data/market_repository.dart';
import '../logic/band_scanner.dart';
import '../models/models.dart';

enum BandScanStatus { idle, running, done, failed }

/// 补齐本地日K缺失股票时的并发路数（每只一轮腾讯/东财日K往返）
const bandBackfillConcurrency = 6;

class BandScanController extends ChangeNotifier {
  /// 总市值下限（亿元），勾选“总市值>40亿”时生效
  static const marketCapMin = 40.0;

  /// v9: 档位分界改 20/40/70/100/…、回落判定重写、去强信号与板块字段，
  /// 旧结果作废
  static const _stateKey = 'band_scan:last:v9';

  final MarketRepository repository;
  final DateTime Function() now;

  /// 基本面标记取数（分红/净利润/估市值），测试可注入假实现
  late final FundamentalsService fundamentals;

  /// LON 多头标记（日/周/月三周期），测试可注入假实现
  late final LonCheckService lonCheck;

  BandScanController(this.repository,
      {DateTime Function()? nowFn,
      FundamentalsService? fundamentals,
      LonCheckService? lonCheck})
      : now = nowFn ?? DateTime.now {
    this.fundamentals = fundamentals ??
        FundamentalsService(
          store: repository.store,
          provider: repository.fundamentalsProvider,
          nowFn: now,
        );
    this.lonCheck = lonCheck ??
        LonCheckService(
          store: repository.store,
          tencent: repository.tencent,
          nowFn: now,
        );
  }

  BandScanStatus status = BandScanStatus.idle;
  String stage = ''; // snapshot | kline | fundamentals | lon | ''
  int total = 0;
  int done = 0;
  List<BandHit> hits = [];
  String? tradeDate;
  double? minMarketCap;
  String? error;

  /// 本地日K缺失/不足20根而未参与判定的股票数（数据完整性提示，非规则排除）
  int skippedNoData = 0;

  /// 上面那批股票的代码，供「补齐」按钮逐只补拉 90 天日K
  List<String> skippedSymbols = [];

  /// 补齐进行中（补齐完成/失败后回 false）
  bool backfilling = false;

  /// 补齐进度：已处理 / 总数
  int backfillDone = 0;
  int backfillTotal = 0;

  /// 补齐结果提示（成功若干只 / 失败原因），点开始扫描后清空
  String? backfillNote;

  /// 同步状态：本地全市场日K的最新交易日（null = 尚无数据/未加载）
  String? dataDate;

  /// 是否已完成首次全量初始化
  bool? initialized;

  /// 扫描参数：总市值>40亿（默认勾选，取消则不过滤）
  bool capFilter = true;

  /// 展示层过滤：只看今日涨停（默认勾选，取消显示全部，无需重扫）
  bool limitUpFilter = true;

  /// 展示层过滤：回落（曾进过更高档、现已回落）默认隐藏，
  /// 勾选后并入列表（无需重扫）
  bool showFromTop = false;

  /// 展示层过滤：只看近一年有分红（含已公告的今年分红），默认关，无需重扫
  bool dividendFilter = false;

  /// 展示层过滤：只看净利润达标（最新报告期归母净利≥0），默认关
  bool profitFilter = false;

  /// 展示层过滤：只看估市值达标（最新报告期营收年化×10>总市值），默认关
  bool revenueFilter = false;

  /// 展示层过滤：只看 LON 多头（日/周/月三周期），默认关
  bool lonFilter = false;

  /// 展示层过滤：只看一路北上（低点在窗口前1/3、最高点在后1/3），默认关
  bool northFilter = false;

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
          (!profitFilter || hit.profitOk) &&
          (!revenueFilter || hit.revenueOk) &&
          (!lonFilter || hit.lonOk) &&
          (!northFilter || hit.northOk))
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

  void setNorthFilter(bool value) {
    if (value == northFilter) return;
    northFilter = value;
    _notify();
  }

  void setRevenueFilter(bool value) {
    if (value == revenueFilter) return;
    revenueFilter = value;
    _notify();
  }

  void setLonFilter(bool value) {
    if (value == lonFilter) return;
    lonFilter = value;
    _notify();
  }

  String get _today => now().toIso8601String().substring(0, 10);

  /// 加载同步状态（初始化标记 + 本地数据最新交易日）
  Future<void> loadSyncStatus() async {
    initialized = await repository.sync.isInitialized();
    dataDate = await repository.sync.latestDataDate();
    _notify();
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
      skippedSymbols = [
        for (final item in (data['skipped_symbols'] as List? ?? const []))
          '$item',
      ];
      // 旧结果没存代码清单时退回计数（补齐按钮此时不可用，重扫即可）
      skippedNoData =
          (data['skipped_no_data'] as num?)?.toInt() ?? skippedSymbols.length;
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
    if (running || backfilling) return;
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
    skippedSymbols = [];
    backfillNote = null;
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

    // 扫描快照顺手写入当日K线（零额外请求）：扫描窗口始终包含最新交易日，
    // 不再依赖启动时的静默增量；失败不影响扫描（用现有本地数据继续）
    try {
      await repository.sync.absorbSnapshot(quotes);
      dataDate = await repository.sync.latestDataDate();
    } catch (_) {}
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
    final missing = <String>[];
    for (final quote in candidates) {
      if (runId != _runId) return;
      final bars = await repository.store.getDailyBars(quote.symbol);
      if (validScanBars(bars).length < scanMinBars) {
        // 本地日K缺失/不足：不是规则排除，单独记录代码供「补齐」按钮用
        missing.add(quote.symbol);
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

    skippedSymbols = missing;

    // 命中股在这里按 symbol → 下标索引，供两个并发阶段回填
    final indexBySymbol = {
      for (var i = 0; i < collected.length; i++) collected[i].symbol: i,
    };

    // 基本面标记（分红/净利润/估市值）：只查命中股，缓存3天；
    // 单只取数失败不影响扫描结果，标记保持默认 false（对齐 scanner.py fundamentals 阶段）。
    // 规则放宽后命中数到 700+，逐只串行要几分钟，这里按
    // fundamentalsFetchConcurrency 路并发（同 sector/同步阶段的 worker 池写法）。
    stage = 'fundamentals';
    hits = List.of(collected);
    _notify();
    final caps = {
      for (final quote in candidates) quote.symbol: quote.marketCap,
    };
    await fundamentals.marksForMany(
      [for (final hit in collected) hit.symbol],
      marketCapOf: (symbol) => caps[symbol],
      shouldStop: () => runId != _runId,
      onEach: (symbol, marks) {
        if (runId != _runId || marks == null) return;
        final index = indexBySymbol[symbol];
        if (index == null) return;
        collected[index] = collected[index].copyWith(
          dividendRecent: marks.dividendRecent,
          profitOk: marks.profitOk,
          revenueOk: marks.revenueOk,
        );
      },
    );
    if (runId != _runId) return;

    // LON 多头标记（日/周/月三周期）：只对命中股计算，周/月K走缓存→腾讯；
    // 单只失败保持默认 false（对齐 scanner.py lon 阶段）。
    // 每只最多三轮网络往返，并发路数比其他阶段保守（lonFetchConcurrency=6）。
    stage = 'lon';
    hits = List.of(collected);
    _notify();
    await lonCheck.lonOkForMany(
      [for (final hit in collected) hit.symbol],
      shouldStop: () => runId != _runId,
      onEach: (symbol, ok) {
        if (runId != _runId || !ok) return;
        final index = indexBySymbol[symbol];
        if (index == null) return;
        collected[index] = collected[index].copyWith(lonOk: true);
      },
    );
    if (runId != _runId) return;

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
        'skipped_symbols': skippedSymbols,
        'finished_at': now().toIso8601String(),
        'hits': [for (final hit in hits) hit.toJson()],
      }),
    );
  }

  /// 补齐本地日K缺失的股票：对 [skippedSymbols] 逐只补拉 90 天日K
  /// （bandBackfillConcurrency 路并发），成功的从清单里移除；
  /// 全部补齐后清空清单并提示可重扫。扫描进行中不允许启动。
  Future<void> backfillMissing() async {
    if (backfilling || running || skippedSymbols.isEmpty) return;
    final runId = ++_runId; // 与扫描共用一个 runId：任一方重启，另一方立刻停
    final pending = List.of(skippedSymbols);
    backfilling = true;
    backfillDone = 0;
    backfillTotal = pending.length;
    backfillNote = null;
    _notify();

    final failed = <String>[];
    final queue = pending.iterator;
    Future<void> worker() async {
      // Iterator 在单 isolate 事件循环内串行推进，无并发竞争
      while (queue.moveNext()) {
        if (runId != _runId) return; // 期间点了重新扫描/页面销毁
        final symbol = queue.current;
        try {
          await repository.sync.refreshSymbol(symbol);
        } catch (_) {
          failed.add(symbol); // 个别失败留在清单里，可再点一次
        }
        backfillDone += 1;
        if (backfillDone % 5 == 0 || backfillDone == backfillTotal) _notify();
      }
    }

    try {
      await Future.wait([
        for (var i = 0; i < bandBackfillConcurrency; i++) worker(),
      ]);
    } catch (exc) {
      if (runId != _runId) return;
      backfilling = false;
      backfillNote = '补齐失败：$exc';
      _notify();
      return;
    }
    if (runId != _runId) return;

    final filled = backfillTotal - failed.length;
    skippedSymbols = failed;
    skippedNoData = failed.length;
    backfilling = false;
    backfillNote = failed.isEmpty
        ? '已补齐 $filled 只，点「重新扫描」纳入判定'
        : '补齐 $filled/$backfillTotal 只，${failed.length} 只取数失败，可再点一次';
    dataDate = await repository.sync.latestDataDate();
    if (runId != _runId) return;
    _notify();
    if (status == BandScanStatus.done) await _persist();
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
