/// 八档局扫描状态控制器：全市场行情快照（东财，腾讯兜底）+
/// 本地 sqlite 已同步的 90 天日 K，流程语义对齐 backend/app/scanner.py。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/market_repository.dart';
import '../logic/band_scanner.dart';
import '../models/models.dart';

enum BandScanStatus { idle, running, done, failed }

class BandScanController extends ChangeNotifier {
  /// 总市值下限（亿元），勾选“总市值>40亿”时生效
  static const marketCapMin = 40.0;

  /// v2: 命中行含 from_top / v_shape 标记，旧结果结构不兼容
  static const _stateKey = 'band_scan:last:v2';

  final MarketRepository repository;
  final DateTime Function() now;

  BandScanController(this.repository, {DateTime Function()? nowFn})
      : now = nowFn ?? DateTime.now;

  BandScanStatus status = BandScanStatus.idle;
  String stage = ''; // snapshot | kline | ''
  int total = 0;
  int done = 0;
  List<BandHit> hits = [];
  String? tradeDate;
  double? minMarketCap;
  String? error;

  /// 扫描参数：总市值>40亿（默认勾选，取消则不过滤）
  bool capFilter = true;

  /// 展示层过滤：只看今日涨停（默认勾选，取消显示全部，无需重扫）
  bool limitUpFilter = true;

  /// 展示层过滤：「从高处来」的两种形态默认隐藏，勾选后并入列表（无需重扫）
  bool showFromTop = false;
  bool showVShape = false;

  int activeGroup = 1;

  bool _disposed = false;
  int _runId = 0;
  bool _restored = false;

  bool get running => status == BandScanStatus.running;

  /// 展示层过滤后的命中
  List<BandHit> get visibleHits => hits
      .where((hit) =>
          (!limitUpFilter || hit.limitUp) &&
          (showFromTop || !hit.fromTop) &&
          (showVShape || !hit.vShape))
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

  void setShowVShape(bool value) {
    if (value == showVShape) return;
    showVShape = value;
    _notify();
  }

  String get _today => now().toIso8601String().substring(0, 10);

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
    final runId = ++_runId;
    // 涨停是展示层过滤（每条命中带 limitUp 标记），扫描本身不过滤，勾选切换即时生效
    final capLimit = capFilter ? marketCapMin : null;
    status = BandScanStatus.running;
    stage = 'snapshot';
    total = 0;
    done = 0;
    hits = [];
    error = null;
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
      final row =
          evaluateStock(quote.symbol, quote.name, quote.price, bars, today: today);
      if (row != null) {
        collected
            .add(row.copyWith(limitUp: isLimitUp(quote.price, quote.preClose)));
      }
      done += 1;
      if (done % 50 == 0) {
        hits = List.of(collected);
        _notify();
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
