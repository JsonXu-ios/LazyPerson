/// 八档局扫描状态控制器。
///
/// **扫描是纯本地的**：整个流程只有一次网络请求（全市场行情快照，用来拿
/// 现价/换手率/市值），其余全部走本地 sqlite 日 K 与已缓存的基本面/LON 标记。
/// 缓存里没有的标记记为"未知"（第三态，不是 false），扫描结束后由界面上的
/// 「补充数据 N 只」按钮显式触发并发拉取（[enrichMarks]）。
///
/// 规则语义仍对齐 backend/app/scanner.py。
library;

import 'dart:async';
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

/// 数据源本身就没有 90 天日K的股票（次新股/长期停牌）。补过一次仍不足的记这里，
/// 之后扫描直接跳过、界面不再提示——用户说过"股票本身数据缺失就不要了"。
const noDataBlacklistKey = 'band:no_data_blacklist:v1';

/// 本地日 K 分块读取的块大小：一次 `symbol IN (...)` 查询覆盖这么多只，
/// 既省 sqlite 往返又不会把整库读进内存
const bandBarsChunkSize = 200;

class BandScanController extends ChangeNotifier {
  /// 总市值下限（亿元），勾选“总市值>40亿”时生效
  static const marketCapMin = 40.0;

  /// v10: 扫描改纯本地、标记变三态、命中行新增 turnover/chg3/chg5/market_cap；
  /// v12: 增加零帧起手（zero_base）名单——旧结果没这批数据，作废重扫
  static const _stateKey = 'band_scan:last:v12';

  final MarketRepository repository;
  final DateTime Function() now;

  /// 基本面标记取数（分红/净利润/估市值），测试可注入假实现
  late final FundamentalsService fundamentals;

  /// LON 多头标记（日/周/月三周期），测试可注入假实现
  late final LonCheckService lonCheck;

  /// 扫描完成后是否自动在后台补数据（日K + 基本面/LON）。
  /// 关掉可以只验证"扫描主流程不联网"这件事（测试用）。
  final bool autoComplete;

  BandScanController(this.repository,
      {DateTime Function()? nowFn,
      FundamentalsService? fundamentals,
      LonCheckService? lonCheck,
      this.autoComplete = true})
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
  String stage = ''; // snapshot | kline | ''
  int total = 0;
  int done = 0;
  List<BandHit> hits = [];
  String? tradeDate;
  double? minMarketCap;
  String? error;

  /// 扫描耗时（毫秒），扫完后显示在页面上；null = 还没扫过
  int? scanMillis;

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

  /// 补齐后仍不足 90 天的只数（次新股/长期停牌，补也补不出来）
  int unfixableCount = 0;

  /// 「补充数据」进行中（基本面 + LON 标记的并发拉取）
  bool enriching = false;

  /// 补充数据进度：已处理 / 总数（基本面与 LON 两段合并计数）
  int enrichDone = 0;
  int enrichTotal = 0;

  /// 补充数据结果提示，重新扫描时清空
  String? enrichNote;

  /// 零帧起手命中：从高处一路下来、现在贴着 90 日低点的（group=0）。
  /// 与 hits 是互斥的两批——八档局只收 pct≥20%，这批正是被它筛掉的地板股，
  /// 所以单独存一份，破势第三个 tab 用。
  List<BandHit> zeroBaseHits = [];

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

  /// 展示层过滤：只看近一年有分红（含已公告的今年分红），默认关，无需重扫。
  /// 标记未知的**不显示**（宁可漏也不误报）。
  bool dividendFilter = false;

  /// 展示层过滤：只看净利润达标（最新报告期归母净利≥0），默认关
  bool profitFilter = false;

  /// 展示层过滤：只看估市值达标（最新报告期营收年化×10>总市值），默认关
  bool revenueFilter = false;

  /// 展示层过滤：只看估市值超2倍（倍数>2，等价市销率<5），默认关
  bool revenue2xFilter = false;

  /// 展示层过滤：只看 LON 多头（日/周/月三周期），默认关
  bool lonFilter = false;

  /// 展示层过滤：只看一路北上（低点在窗口前1/3、最高点在后1/3），默认关
  bool northFilter = false;

  /// 展示层过滤：当日换手率 > 3%，默认关（null = 快照没给换手率 → 过滤掉）
  bool turnoverFilter = false;

  /// 展示层过滤：近 3 日涨幅 > 7%，默认关
  bool chg3Filter = false;

  /// 展示层过滤：近 5 日涨幅 > 14%，默认关
  bool chg5Filter = false;

  int activeGroup = 1;

  bool _disposed = false;
  int _runId = 0;
  bool _restored = false;

  /// 数据源本身没有 90 天日K的股票（次新/长期停牌），扫描直接跳过
  final Set<String> _noDataBlacklist = {};

  bool get running => status == BandScanStatus.running;

  /// 忙碌中（扫描/补齐/补充数据任一进行中）：三者互斥
  bool get busy => running || backfilling || enriching;

  /// 展示层过滤后的命中（对齐 MoneyGrabPanel.tsx 的 visibleHits）。
  /// 三态标记的语义：勾选后只显示**确定**达标的，未知（null）一律不显示。
  List<BandHit> get visibleHits => hits
      .where((hit) =>
          (!limitUpFilter || hit.limitUp) &&
          (showFromTop || !hit.fromTop) &&
          (!dividendFilter || hit.dividendRecent == true) &&
          (!profitFilter || hit.profitOk == true) &&
          (!revenueFilter || hit.revenueOk == true) &&
          (!revenue2xFilter ||
              (hit.revenueRatio != null && hit.revenueRatio! > 2)) &&
          (!lonFilter || hit.lonOk == true) &&
          (!northFilter || hit.northOk) &&
          (!turnoverFilter ||
              (hit.turnover != null && hit.turnover! > turnoverFilterMin)) &&
          (!chg3Filter || (hit.chg3 != null && hit.chg3! > chg3FilterMin)) &&
          (!chg5Filter || (hit.chg5 != null && hit.chg5! > chg5FilterMin)))
      .toList();

  /// 基本面/LON 标记还没补充的命中代码（「补充数据 N 只」按钮用）
  List<String> get unknownMarkSymbols =>
      [for (final hit in hits) if (!hit.marksKnown) hit.symbol];

  /// 同上的数量，0 = 全部标记都已确定
  int get unknownMarkCount => unknownMarkSymbols.length;

  /// 当前是否有依赖标记的筛选开关被打开（决定要不要提示“有 N 只数据未补充”）
  bool get markFilterActive =>
      dividendFilter || profitFilter || revenueFilter || revenue2xFilter || lonFilter;

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

  void setCapFilter(bool value) => _setFlag(value, capFilter, (v) => capFilter = v);

  void setLimitUpFilter(bool value) =>
      _setFlag(value, limitUpFilter, (v) => limitUpFilter = v);

  void setShowFromTop(bool value) =>
      _setFlag(value, showFromTop, (v) => showFromTop = v);

  void setDividendFilter(bool value) =>
      _setFlag(value, dividendFilter, (v) => dividendFilter = v);

  void setProfitFilter(bool value) =>
      _setFlag(value, profitFilter, (v) => profitFilter = v);

  void setNorthFilter(bool value) =>
      _setFlag(value, northFilter, (v) => northFilter = v);

  void setRevenueFilter(bool value) =>
      _setFlag(value, revenueFilter, (v) => revenueFilter = v);

  void setRevenue2xFilter(bool value) =>
      _setFlag(value, revenue2xFilter, (v) => revenue2xFilter = v);

  void setLonFilter(bool value) => _setFlag(value, lonFilter, (v) => lonFilter = v);

  void setTurnoverFilter(bool value) =>
      _setFlag(value, turnoverFilter, (v) => turnoverFilter = v);

  void setChg3Filter(bool value) =>
      _setFlag(value, chg3Filter, (v) => chg3Filter = v);

  void setChg5Filter(bool value) =>
      _setFlag(value, chg5Filter, (v) => chg5Filter = v);

  void _setFlag(bool value, bool current, void Function(bool) assign) {
    if (value == current) return;
    assign(value);
    _notify();
  }

  String get _today => now().toIso8601String().substring(0, 10);

  /// 加载同步状态（初始化标记 + 本地数据最新交易日 + 无数据黑名单）
  Future<void> loadSyncStatus() async {
    initialized = await repository.sync.isInitialized();
    dataDate = await repository.sync.latestDataDate();
    try {
      final raw = await repository.store.getState(noDataBlacklistKey);
      if (raw != null) {
        _noDataBlacklist
          ..clear()
          ..addAll((jsonDecode(raw) as List).map((item) => '$item'));
      }
    } catch (_) {
      // 黑名单损坏就当空的，大不了再补一次
    }
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
      zeroBaseHits = [
        for (final row in (data['zero_base'] as List? ?? const []))
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
      scanMillis = (data['scan_ms'] as num?)?.toInt();
      capFilter = minMarketCap != null;
      status = BandScanStatus.done;
      _notify();
      // 上次那轮补数据可能没补全（取数失败/中途退出 App），恢复当天结果后接着补。
      // 补不动的仍会剩在那儿，页面上有手动重试入口。
      if (autoComplete && unknownMarkCount > 0) unawaited(_autoComplete());
    } catch (_) {
      // 恢复失败按无结果处理
    }
  }

  Future<void> startScan() async {
    if (busy) return;
    // 全市场日K未同步完成时本地数据残缺，扫描结果会漏股票（如刚安装的设备），直接拒绝
    if (!await repository.sync.isInitialized()) {
      status = BandScanStatus.failed;
      stage = '';
      error = '全市场日K尚未同步完成：请回自选页等待初始化同步结束后再扫描';
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
    zeroBaseHits = [];
    error = null;
    skippedNoData = 0;
    skippedSymbols = [];
    unfixableCount = 0;
    backfillNote = null;
    enrichNote = null;
    scanMillis = null;
    tradeDate = _today;
    minMarketCap = capLimit;
    _notify();
    final startedAt = DateTime.now();
    try {
      await _run(runId, capLimit);
      if (runId != _runId) return;
      scanMillis = DateTime.now().difference(startedAt).inMilliseconds;
      _notify();
      await _persist();
    } catch (exc) {
      if (runId != _runId) return;
      status = BandScanStatus.failed;
      stage = '';
      error = '$exc';
      _notify();
    }
  }

  /// 扫描主流程：1 次快照请求 + 本地日 K + 已缓存标记，全程不再逐只打网络。
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

    // 已缓存的基本面/LON 标记：各一次前缀查询，扫描期间不发任何请求
    final symbols = [for (final quote in candidates) quote.symbol];
    final fundCache = await fundamentals.cachedMarksForMany(symbols);
    final lonCache = await lonCheck.cachedOkForMany(symbols);
    if (runId != _runId) return;

    final today = now();
    final collected = <BandHit>[];
    final zeroBase = <BandHit>[];
    final missing = <String>[];

    for (var offset = 0; offset < candidates.length; offset += bandBarsChunkSize) {
      if (runId != _runId) return;
      final end = offset + bandBarsChunkSize > candidates.length
          ? candidates.length
          : offset + bandBarsChunkSize;
      final chunk = candidates.sublist(offset, end);
      final barsBySymbol = await repository.store
          .dailyBarsFor([for (final quote in chunk) quote.symbol]);
      if (runId != _runId) return;
      for (final quote in chunk) {
        final bars = barsBySymbol[quote.symbol] ?? const <KlineBar>[];
        if (validScanBars(bars).length < scanMinBars) {
          // 本地日K不足。黑名单里的（次新股/长期停牌，补过也补不出来）静默跳过，
          // 其余记下来由扫描后的自动补齐处理，界面不打扰用户。
          if (!_noDataBlacklist.contains(quote.symbol)) {
            missing.add(quote.symbol);
            skippedNoData += 1;
          }
        } else {
          // 零帧起手与八档局互斥：pct≥20% 的进 hits，贴着低点的进 zeroBase
          final floor = evaluateZeroBase(
              quote.symbol, quote.name, quote.price, bars,
              today: today);
          if (floor != null) {
            zeroBase.add(floor.copyWith(
              turnover: quote.turnover,
              marketCap: quote.marketCap,
            ));
          }
          final row = evaluateStock(quote.symbol, quote.name, quote.price, bars,
              today: today);
          if (row != null) {
            final marks = fundCache[quote.symbol];
            collected.add(row.copyWith(
              limitUp: isLimitUp(quote.price, quote.preClose),
              turnover: quote.turnover,
              marketCap: quote.marketCap,
              // 缓存没有的保持 null = 未知，由「补充数据」按钮补
              dividendRecent: marks?.dividendRecent,
              profitOk: marks?.profitOk,
              revenueOk: marks?.revenueOk,
              lonOk: lonCache[quote.symbol],
            ));
          }
        }
        done += 1;
      }
      hits = List.of(collected);
      _notify();
    }

    skippedSymbols = missing;
    // 摔得最狠的排前面（高点越高，跌回原地的落差越大）
    zeroBase.sort((a, b) => b.maxPct.compareTo(a.maxPct));
    zeroBaseHits = zeroBase;
    collected.sort((a, b) {
      final byGroup = a.group.compareTo(b.group);
      if (byGroup != 0) return byGroup;
      return b.over.compareTo(a.over);
    });
    hits = collected;
    status = BandScanStatus.done;
    stage = '';
    _notify();

    // 扫完自动把缺的补上：先补日K（补不出来的进黑名单，以后不再打扰），
    // 再补基本面/LON 标记。全程后台跑，用户不用点任何按钮。
    if (autoComplete) unawaited(_autoComplete());
  }

  /// 扫描后的自动补数据：日K缺失 → 基本面/LON 标记。
  /// 任一步失败都静默（结果照常可用），下次扫描会再试。
  Future<void> _autoComplete() async {
    if (skippedSymbols.isNotEmpty) {
      await backfillMissing(silent: true);
    }
    if (unknownMarkCount > 0) {
      await enrichMarks(silent: true);
    }
  }

  /// 「补充数据 N 只」：只有用户显式点击才会发这批网络请求。
  /// 基本面（每只最多 2 请求）与 LON（每只最多 3 请求）分两段并发跑，
  /// 复用与扫描阶段同一套 worker 池；单只失败保持"未知"，可以再点一次。
  Future<void> enrichMarks({bool silent = false}) async {
    if (busy && !silent) return;
    final targets = [for (final hit in hits) if (!hit.marksKnown) hit];
    if (targets.isEmpty) return;
    final runId = ++_runId; // 与扫描/补齐共用：任一方重启，其余立刻停
    final updated = List.of(hits);
    final indexBySymbol = {
      for (var i = 0; i < updated.length; i++) updated[i].symbol: i,
    };
    final fundTargets = [
      for (final hit in targets)
        if (!hit.fundamentalsKnown) hit.symbol,
    ];
    final lonTargets = [
      for (final hit in targets)
        if (!hit.lonKnown) hit.symbol,
    ];
    final caps = {
      for (final hit in hits) hit.symbol: hit.marketCap,
    };

    enriching = true;
    enrichDone = 0;
    enrichTotal = fundTargets.length + lonTargets.length;
    enrichNote = null;
    _notify();

    var failed = 0;
    void tick() {
      enrichDone += 1;
      if (enrichDone % 10 == 0 || enrichDone == enrichTotal) {
        hits = List.of(updated);
        _notify();
      }
    }

    try {
      await fundamentals.marksForMany(
        fundTargets,
        marketCapOf: (symbol) => caps[symbol],
        shouldStop: () => runId != _runId,
        onEach: (symbol, marks) {
          if (runId != _runId) return;
          if (marks == null) {
            failed += 1; // 取数失败：保持未知，可再点一次
          } else {
            final index = indexBySymbol[symbol];
            if (index != null) {
              updated[index] = updated[index].copyWith(
                dividendRecent: marks.dividendRecent,
                profitOk: marks.profitOk,
                revenueOk: marks.revenueOk,
                revenueRatio: marks.revenueRatioValue,
              );
            }
          }
          tick();
        },
      );
      if (runId != _runId) return;

      await lonCheck.lonOkForMany(
        lonTargets,
        shouldStop: () => runId != _runId,
        onEach: (symbol, ok) {
          if (runId != _runId) return;
          if (ok == null) {
            failed += 1;
          } else {
            final index = indexBySymbol[symbol];
            if (index != null) {
              updated[index] = updated[index].copyWith(lonOk: ok);
            }
          }
          tick();
        },
      );
    } catch (exc) {
      if (runId != _runId) return;
      hits = updated;
      enriching = false;
      enrichNote = '补充数据失败：$exc';
      _notify();
      return;
    }
    if (runId != _runId) return;

    hits = updated;
    enriching = false;
    final remaining = unknownMarkCount;
    enrichNote = failed == 0
        ? '已补充 ${enrichTotal - failed} 项数据'
        : '补充 ${enrichTotal - failed}/$enrichTotal 项，$remaining 只仍未知，可再点一次';
    _notify();
    if (status == BandScanStatus.done) await _persist();
  }

  Future<void> _persist() async {
    await repository.store.setState(
      _stateKey,
      jsonEncode({
        'trade_date': tradeDate,
        'min_market_cap': minMarketCap,
        'total': total,
        'scan_ms': scanMillis,
        'skipped_no_data': skippedNoData,
        'skipped_symbols': skippedSymbols,
        'finished_at': now().toIso8601String(),
        'hits': [for (final hit in hits) hit.toJson()],
        'zero_base': [for (final hit in zeroBaseHits) hit.toJson()],
      }),
    );
  }

  /// 补齐本地日K缺失的股票：对 [skippedSymbols] 逐只补拉 90 天日K
  /// （bandBackfillConcurrency 路并发），成功的从清单里移除；
  /// 全部补齐后清空清单并提示可重扫。扫描进行中不允许启动。
  Future<void> backfillMissing({bool silent = false}) async {
    if ((busy && !silent) || skippedSymbols.isEmpty) return;
    final runId = ++_runId; // 与扫描共用一个 runId：任一方重启，另一方立刻停
    final pending = List.of(skippedSymbols);
    backfilling = true;
    backfillDone = 0;
    backfillTotal = pending.length;
    backfillNote = null;
    _notify();

    final failed = <String>[];      // 取数失败，可再点一次
    final unfixable = <String>[];   // 取回来了但数据源本身就不足 90 天（次新/长期停牌）
    final queue = pending.iterator;
    Future<void> worker() async {
      // Iterator 在单 isolate 事件循环内串行推进，无并发竞争
      while (queue.moveNext()) {
        if (runId != _runId) return; // 期间点了重新扫描/页面销毁
        final symbol = queue.current;
        try {
          await repository.sync.refreshSymbol(symbol);
          // 关键：补完要校验真的够用了。次新股/长期停牌股即使拉取成功也不够
          // 20 根，之前会被反复算进"待补齐"，看起来就是"点了还是失败"。
          final bars = await repository.store.getDailyBars(symbol);
          if (validScanBars(bars).length < scanMinBars) {
            unfixable.add(symbol);
          }
        } catch (_) {
          failed.add(symbol);
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

    final filled = backfillTotal - failed.length - unfixable.length;
    // 只有"取数失败"的留在待补清单里；数据源本身不足的不再反复提示
    skippedSymbols = failed;
    skippedNoData = failed.length;
    unfixableCount = unfixable.length;
    if (unfixable.isNotEmpty) {
      // 数据源本身就没有 90 天数据：进黑名单，之后扫描直接跳过、不再提示
      _noDataBlacklist.addAll(unfixable);
      await repository.store
          .setState(noDataBlacklistKey, jsonEncode(_noDataBlacklist.toList()));
    }
    backfilling = false;
    final parts = <String>['已补齐 $filled 只'];
    if (unfixable.isNotEmpty) {
      parts.add('${unfixable.length} 只上市不足90天/长期停牌，无法补齐');
    }
    if (failed.isNotEmpty) {
      parts.add('${failed.length} 只取数失败可再点一次');
    }
    backfillNote = failed.isEmpty && unfixable.isEmpty
        ? '已补齐 $filled 只，点「重新扫描」纳入判定'
        : parts.join('，');
    dataDate = await repository.sync.latestDataDate();
    if (runId != _runId) return;
    _notify();
    if (status == BandScanStatus.done) await _persist();
  }

  /// 全市场A股快照：东财 clist（内置主备域名）优先，失败或残缺时
  /// 用本地清单分批走腾讯行情兜底（对齐 scanner.py::_fetch_all_a_quotes）。
  /// 这是整个扫描流程里唯一的网络请求。
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
