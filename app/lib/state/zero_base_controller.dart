/// 零帧起手扫描控制器（破势第三个 tab 专用，与八档局互不相干）。
///
/// 找的是"从高处一路下来、现在停在 90 日低点上"的股票。八档局只收
/// pct ≥ 20% 的，这批永远进不去它的结果，所以这里自己跑一遍：
/// 1 次全市场快照（顺手把当日 bar 落库，所以**当天的行情算在内**）
/// → 本地日 K 逐只判定 → 基本面标记（分红/净利润/估市值）后台补。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/fundamentals_service.dart';
import '../data/market_repository.dart';
import '../logic/band_scanner.dart';
import '../models/models.dart';

enum ZeroBaseStatus { idle, running, done, failed }

/// 本地日 K 分块读取的块大小（与八档局同一套口径）
const zeroBaseChunkSize = 200;

class ZeroBaseController extends ChangeNotifier {
  static const _stateKey = 'zero_base:last:v1';

  final MarketRepository repository;
  final DateTime Function() now;

  /// 基本面标记取数（分红/净利润/估市值），测试可注入假实现
  late final FundamentalsService fundamentals;

  /// 扫完自动在后台补基本面标记（测试可关掉）
  final bool autoComplete;

  ZeroBaseController(
    this.repository, {
    DateTime Function()? nowFn,
    FundamentalsService? fundamentals,
    this.autoComplete = true,
  }) : now = nowFn ?? DateTime.now {
    this.fundamentals = fundamentals ??
        FundamentalsService(
          store: repository.store,
          provider: repository.fundamentalsProvider,
          nowFn: now,
        );
  }

  ZeroBaseStatus status = ZeroBaseStatus.idle;
  String stage = ''; // snapshot | kline | ''
  int total = 0;
  int done = 0;
  List<BandHit> hits = [];
  String? tradeDate;
  String? error;
  int? scanMillis;

  /// 基本面补充中 + 进度
  bool enriching = false;
  int enrichDone = 0;
  int enrichTotal = 0;
  String? enrichNote;

  /// 展示层筛选（切换即时生效，不用重扫）。三态标记未知的一律不显示。
  bool dividendFilter = false;
  bool profitFilter = false;
  bool revenueFilter = false;
  bool turnoverFilter = false;

  bool _disposed = false;
  int _runId = 0;
  bool _restored = false;

  bool get running => status == ZeroBaseStatus.running;

  bool get busy => running || enriching;

  List<BandHit> get visibleHits => hits
      .where((hit) =>
          (!dividendFilter || hit.dividendRecent == true) &&
          (!profitFilter || hit.profitOk == true) &&
          (!revenueFilter || hit.revenueOk == true) &&
          (!turnoverFilter ||
              (hit.turnover != null && hit.turnover! > turnoverFilterMin)))
      .toList();

  /// 按"曾站上过的最高主线"分组（从多高摔下来的），每只只归最高一组
  Map<int, List<BandHit>> get byPeak {
    final grouped = <int, List<BandHit>>{};
    for (final hit in visibleHits) {
      final stage = breakoutStage(hit.maxPct);
      if (stage == null) continue;
      grouped.putIfAbsent(stage, () => []).add(hit);
    }
    for (final list in grouped.values) {
      list.sort((a, b) => b.maxPct.compareTo(a.maxPct)); // 摔得最狠的在前
    }
    return grouped;
  }

  /// 基本面标记还没补上的只数（0 = 都齐了）
  int get unknownMarkCount => hits.where((hit) => !hit.fundamentalsKnown).length;

  String get _today => now().toIso8601String().substring(0, 10);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _runId += 1;
    super.dispose();
  }

  void setDividendFilter(bool value) =>
      _setFlag(value, dividendFilter, (v) => dividendFilter = v);

  void setProfitFilter(bool value) =>
      _setFlag(value, profitFilter, (v) => profitFilter = v);

  void setRevenueFilter(bool value) =>
      _setFlag(value, revenueFilter, (v) => revenueFilter = v);

  void setTurnoverFilter(bool value) =>
      _setFlag(value, turnoverFilter, (v) => turnoverFilter = v);

  void _setFlag(bool value, bool current, void Function(bool) assign) {
    if (value == current) return;
    assign(value);
    _notify();
  }

  /// 恢复当天扫描结果（隔日作废，与八档局同一套语义）
  Future<void> restore() async {
    if (_restored || status != ZeroBaseStatus.idle) return;
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
      done = total;
      tradeDate = data['trade_date'] as String?;
      scanMillis = (data['scan_ms'] as num?)?.toInt();
      status = ZeroBaseStatus.done;
      _notify();
      // 上次没补完的接着补（重开 App 不用重扫）
      if (autoComplete && unknownMarkCount > 0) {
        unawaited(enrichMarks(silent: true));
      }
    } catch (_) {
      // 恢复失败按无结果处理
    }
  }

  Future<void> startScan() async {
    if (busy) return;
    final runId = ++_runId;
    status = ZeroBaseStatus.running;
    stage = 'snapshot';
    total = 0;
    done = 0;
    hits = [];
    error = null;
    enrichNote = null;
    scanMillis = null;
    tradeDate = _today;
    _notify();
    final startedAt = DateTime.now();
    try {
      await _run(runId);
      if (runId != _runId) return;
      scanMillis = DateTime.now().difference(startedAt).inMilliseconds;
      _notify();
      await _persist();
      if (autoComplete && unknownMarkCount > 0) {
        unawaited(enrichMarks(silent: true));
      }
    } catch (exc) {
      if (runId != _runId) return;
      status = ZeroBaseStatus.failed;
      stage = '';
      error = '$exc';
      _notify();
    }
  }

  Future<void> _run(int runId) async {
    final quotes = await repository.fullMarketQuotes();
    if (runId != _runId) return;

    // 快照顺手写入当日 K 线：**当天的行情因此算在扫描窗口里**
    try {
      await repository.sync.absorbSnapshot(quotes);
    } catch (_) {
      // 落库失败不影响判定，用现有本地数据继续
    }
    if (runId != _runId) return;

    final candidates = quotes
        .where((quote) =>
            eligibleSymbol(quote.symbol, quote.name) && quote.price != null)
        .toList();
    total = candidates.length;
    stage = 'kline';
    _notify();

    // 已缓存的基本面标记：一次前缀查询，扫描期间不发请求
    final fundCache = await fundamentals
        .cachedMarksForMany([for (final quote in candidates) quote.symbol]);
    if (runId != _runId) return;

    final today = now();
    final collected = <BandHit>[];
    for (var offset = 0;
        offset < candidates.length;
        offset += zeroBaseChunkSize) {
      if (runId != _runId) return;
      final end = offset + zeroBaseChunkSize > candidates.length
          ? candidates.length
          : offset + zeroBaseChunkSize;
      final chunk = candidates.sublist(offset, end);
      final barsBySymbol = await repository.store
          .dailyBarsFor([for (final quote in chunk) quote.symbol]);
      if (runId != _runId) return;
      for (final quote in chunk) {
        final bars = barsBySymbol[quote.symbol] ?? const <KlineBar>[];
        final row = evaluateZeroBase(
            quote.symbol, quote.name, quote.price, bars,
            today: today);
        if (row != null) {
          final marks = fundCache[quote.symbol];
          collected.add(row.copyWith(
            turnover: quote.turnover,
            marketCap: quote.marketCap,
            dividendRecent: marks?.dividendRecent,
            profitOk: marks?.profitOk,
            revenueOk: marks?.revenueOk,
            revenueRatio: marks?.revenueRatioValue,
          ));
        }
        done += 1;
      }
      hits = List.of(collected);
      _notify();
    }

    // 摔得最狠的排前面（高点越高，跌回原地的落差越大）
    collected.sort((a, b) => b.maxPct.compareTo(a.maxPct));
    hits = collected;
    status = ZeroBaseStatus.done;
    stage = '';
    _notify();
  }

  /// 补基本面标记（分红/净利润/估市值）。自动跑一次；剩下的可以手动再点。
  Future<void> enrichMarks({bool silent = false}) async {
    if (busy && !silent) return;
    final targets = [for (final hit in hits) if (!hit.fundamentalsKnown) hit];
    if (targets.isEmpty) return;
    final runId = ++_runId;
    final updated = List.of(hits);
    final indexBySymbol = {
      for (var i = 0; i < updated.length; i++) updated[i].symbol: i,
    };
    final caps = {for (final hit in hits) hit.symbol: hit.marketCap};

    enriching = true;
    enrichDone = 0;
    enrichTotal = targets.length;
    enrichNote = null;
    _notify();

    var failed = 0;
    try {
      await fundamentals.marksForMany(
        [for (final hit in targets) hit.symbol],
        marketCapOf: (symbol) => caps[symbol],
        shouldStop: () => runId != _runId,
        onEach: (symbol, marks) {
          if (runId != _runId) return;
          if (marks == null) {
            failed += 1; // 取数失败：保持未知，可以再点一次
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
          enrichDone += 1;
          if (enrichDone % 10 == 0 || enrichDone == enrichTotal) {
            hits = List.of(updated);
            _notify();
          }
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
    enrichNote = failed == 0
        ? '已补充 $enrichTotal 只'
        : '补充 ${enrichTotal - failed}/$enrichTotal 只，$unknownMarkCount 只仍未知，可再点一次';
    _notify();
    if (status == ZeroBaseStatus.done) await _persist();
  }

  Future<void> _persist() async {
    await repository.store.setState(
      _stateKey,
      jsonEncode({
        'trade_date': tradeDate,
        'total': total,
        'scan_ms': scanMillis,
        'finished_at': now().toIso8601String(),
        'hits': [for (final hit in hits) hit.toJson()],
      }),
    );
  }
}
