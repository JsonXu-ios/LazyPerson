/// 八档局扫描控制器测试：扫描完成后并发补 dividendRecent/profitOk/revenueOk
/// （注入假基本面取数）与 lonOk（注入假 LON 校验），取数失败不影响扫描结果；
/// 展示层过滤开关对齐网页版 MoneyGrabPanel；本地日K缺失的股票记进
/// skippedSymbols 并可一键补齐。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/fundamentals_service.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/lon_check_service.dart';
import 'package:lazyperson/data/market_repository.dart';
import 'package:lazyperson/data/providers/eastmoney_provider.dart';
import 'package:lazyperson/data/sync_service.dart';
import 'package:lazyperson/logic/band_scanner.dart';
import 'package:lazyperson/models/models.dart';
import 'package:lazyperson/state/band_scan_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeEastmoney extends EastmoneyProvider {
  final List<Quote> quotes;

  _FakeEastmoney(this.quotes);

  @override
  Future<List<Quote>> fullMarketSnapshot(
          {void Function(int loaded, int total)? onProgress}) async =>
      quotes;
}

/// 注入的假基本面取数：记录调用参数；映射里没有的股票视为取数失败。
/// [delay] 用来观察 marksForMany 的并发度（inFlight 峰值）。
class _FakeFundamentals extends FundamentalsService {
  final Map<String, FundamentalsMarks> marks;
  final Duration delay;
  final List<String> requested = [];
  final Map<String, double?> capsSeen = {};
  int inFlight = 0;
  int maxInFlight = 0;

  _FakeFundamentals(LocalStore store, this.marks,
      {this.delay = Duration.zero})
      : super(store: store);

  @override
  Future<FundamentalsMarks> marksFor(String symbol, double? marketCapYi) async {
    requested.add(symbol);
    capsSeen[symbol] = marketCapYi;
    inFlight += 1;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final found = marks[symbol];
      if (found == null) throw StateError('fetch failed: $symbol');
      return found;
    } finally {
      inFlight -= 1;
    }
  }
}

/// 注入的假 LON 校验：映射里没有的股票视为取数失败（保持默认 false）。
/// [delay] 用来观察 lonOkForMany 的并发度。
class _FakeLonCheck extends LonCheckService {
  final Map<String, bool> results;
  final Duration delay;
  final List<String> requested = [];
  int inFlight = 0;
  int maxInFlight = 0;

  _FakeLonCheck(LocalStore store, this.results, {this.delay = Duration.zero})
      : super(store: store);

  @override
  Future<bool> lonOkFor(String symbol) async {
    requested.add(symbol);
    inFlight += 1;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final found = results[symbol];
      if (found == null) throw StateError('lon failed: $symbol');
      return found;
    } finally {
      inFlight -= 1;
    }
  }
}

final _today = DateTime(2026, 7, 24); // 周五

/// 假同步服务：refreshSymbol 把 90 天日K写进本地库（模拟补齐成功），
/// [failing] 里的股票抛错（模拟单只补齐失败）
class _FakeSync extends SyncService {
  final Set<String> failing;
  final Duration delay;
  final List<String> refreshed = [];
  int inFlight = 0;
  int maxInFlight = 0;

  _FakeSync({
    required super.store,
    required EastmoneyProvider eastmoney,
    this.failing = const {},
    this.delay = Duration.zero,
  }) : super(eastmoney: eastmoney);

  @override
  Future<void> refreshSymbol(String symbol) async {
    refreshed.add(symbol);
    inFlight += 1;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (failing.contains(symbol)) {
        throw StateError('refresh failed: $symbol');
      }
      await store.upsertDailyBars(symbol, _waveBars());
    } finally {
      inFlight -= 1;
    }
  }
}

/// 200 天日线：平台 + 波段低点 + 尾部按 closesPct 相对低点的涨幅收盘
List<KlineBar> _waveBars({double low = 10.0, List<double> closesPct = const [5, 12, 32]}) {
  final bars = <KlineBar>[];
  for (var offset = 200; offset >= 0; offset--) {
    final day = _today.subtract(Duration(days: offset));
    if (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday) {
      continue;
    }
    bars.add(KlineBar(
      time: day.toIso8601String().substring(0, 10),
      open: low * 1.05,
      high: low * 1.08,
      low: low * 1.05,
      close: low * 1.06,
    ));
  }
  final tail = closesPct.length;
  final lowIndex = bars.length - tail - 1;
  bars[lowIndex] = KlineBar(
    time: bars[lowIndex].time,
    open: low * 1.05,
    high: low * 1.08,
    low: low, // 波段低点
    close: low * 1.06,
  );
  for (var i = 0; i < tail; i++) {
    final index = bars.length - tail + i;
    final price = low * (1 + closesPct[i] / 100);
    bars[index] = KlineBar(
      time: bars[index].time,
      open: price * 0.99,
      high: price * 1.01,
      low: math.min(low * 1.05, price),
      close: price,
    );
  }
  return bars;
}

Quote _quote(String symbol, String name, {double price = 13.5}) => Quote(
      symbol: symbol,
      market: 'SH',
      name: name,
      price: price, // 默认 13.5：相对低点 10 涨 35% → 一档
      preClose: 13.0,
      marketCap: 100.0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late MarketRepository repository;
  late _FakeSync sync;
  late _FakeFundamentals fundamentals;
  late _FakeLonCheck lonCheck;
  late BandScanController controller;

  Future<void> setUpScan(Map<String, FundamentalsMarks> marks,
      {Map<String, bool> lonResults = const {},
      Duration fundamentalsDelay = Duration.zero,
      Duration lonDelay = Duration.zero,
      Duration backfillDelay = Duration.zero,
      Set<String> backfillFailing = const {},
      List<Quote>? quoteOverride,
      Set<String> withoutBars = const {}}) async {
    store = LocalStore(await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => LocalStore.createSchema(db),
      ),
    ));
    final quotes = quoteOverride ??
        [
          _quote('600001', '甲股'),
          _quote('600002', '乙股'),
          _quote('600003', '丙股'),
        ];
    sync = _FakeSync(
      store: store,
      eastmoney: _FakeEastmoney(quotes),
      failing: backfillFailing,
      delay: backfillDelay,
    );
    repository = MarketRepository(store: store, sync: sync);
    await store.setState('initial_sync_done', '1');
    for (final quote in quotes) {
      // withoutBars 里的股票本地没有日K → 扫描时计入 skippedSymbols
      if (withoutBars.contains(quote.symbol)) continue;
      await store.upsertDailyBars(quote.symbol, _waveBars());
    }
    fundamentals = _FakeFundamentals(store, marks, delay: fundamentalsDelay);
    lonCheck = _FakeLonCheck(store, lonResults, delay: lonDelay);
    controller = BandScanController(
      repository,
      nowFn: () => _today,
      fundamentals: fundamentals,
      lonCheck: lonCheck,
    );
  }

  tearDown(() => store.close());

  test('扫描完成后并发补标记；取数失败的股票保持默认 false 且不影响扫描结果', () async {
    await setUpScan({
      '600001': const FundamentalsMarks(
          dividendRecent: true, profitOk: true, revenueOk: true),
      '600003': const FundamentalsMarks(
          dividendRecent: false, profitOk: true, revenueOk: false),
      // 600002 缺失 → marksFor 抛异常，模拟取数失败
    }, lonResults: {
      '600001': true,
      '600003': false,
      // 600002 缺失 → lonOkFor 抛异常，模拟取数失败
    });

    await controller.startScan();

    expect(controller.status, BandScanStatus.done);
    expect(controller.stage, '');
    expect(controller.hits, hasLength(3));
    // 只对命中的股票取数，市值来自扫描快照的 Quote.marketCap（亿元）
    expect(fundamentals.requested.toSet(), {'600001', '600002', '600003'});
    expect(fundamentals.capsSeen['600001'], 100.0);
    // lon 阶段同样只对命中股计算
    expect(lonCheck.requested.toSet(), {'600001', '600002', '600003'});

    final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
    expect(bySymbol['600001']!.dividendRecent, isTrue);
    expect(bySymbol['600001']!.profitOk, isTrue);
    expect(bySymbol['600001']!.revenueOk, isTrue);
    expect(bySymbol['600001']!.lonOk, isTrue);
    expect(bySymbol['600002']!.dividendRecent, isFalse); // 取数失败 → 默认 false
    expect(bySymbol['600002']!.profitOk, isFalse);
    expect(bySymbol['600002']!.revenueOk, isFalse);
    expect(bySymbol['600002']!.lonOk, isFalse);
    expect(bySymbol['600003']!.dividendRecent, isFalse);
    expect(bySymbol['600003']!.profitOk, isTrue);
    expect(bySymbol['600003']!.revenueOk, isFalse);
    expect(bySymbol['600003']!.lonOk, isFalse);
  });

  test('分红/净利润/估市值/LON 是展示层过滤（默认关），切换无需重扫', () async {
    await setUpScan({
      '600001': const FundamentalsMarks(
          dividendRecent: true, profitOk: true, revenueOk: true),
      '600002': const FundamentalsMarks(
          dividendRecent: true, profitOk: false, revenueOk: true),
      '600003': const FundamentalsMarks(
          dividendRecent: false, profitOk: true, revenueOk: false),
    }, lonResults: {
      '600001': true,
      '600002': false,
      '600003': true,
    });
    await controller.startScan();
    controller.setLimitUpFilter(false); // 测试数据无涨停，先放开

    // 默认全不勾选 → 不过滤（对齐 MoneyGrabPanel 四个开关默认关）
    expect(controller.dividendFilter, isFalse);
    expect(controller.profitFilter, isFalse);
    expect(controller.revenueFilter, isFalse);
    expect(controller.lonFilter, isFalse);
    expect(controller.visibleHits, hasLength(3));

    controller.setDividendFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol).toSet(),
        {'600001', '600002'});

    controller.setDividendFilter(false);
    controller.setProfitFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol).toSet(),
        {'600001', '600003'});

    controller.setProfitFilter(false);
    controller.setRevenueFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol).toSet(),
        {'600001', '600002'});

    controller.setRevenueFilter(false);
    controller.setLonFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol).toSet(),
        {'600001', '600003'});

    // 四个全开取交集（&& 语义对齐 MoneyGrabPanel.visibleHits）
    controller.setDividendFilter(true);
    controller.setProfitFilter(true);
    controller.setRevenueFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);
  });

  test('标记随结果持久化（key v9），当日 restore 恢复；v8 旧结果作废', () async {
    await setUpScan({
      '600001': const FundamentalsMarks(
          dividendRecent: true, profitOk: true, revenueOk: true),
    }, lonResults: {
      '600001': true,
    });
    await store.setState(
      'band_scan:last:v8',
      jsonEncode({
        'trade_date': _today.toIso8601String().substring(0, 10),
        'total': 1,
        'hits': const [
          {
            'symbol': '600009',
            'price': 13.5,
            'low90': 10.0,
            'pct': 35.0,
            'group': 1,
            'threshold': 20.0,
            'over': 15.0,
            'max_pct': 35.0,
          }
        ],
      }),
    );
    await controller.startScan();

    final raw = await store.getState('band_scan:last:v9');
    expect(raw, isNotNull);
    final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
    final rows = (persisted['hits'] as List).cast<Map>();
    final row = rows.firstWhere((item) => item['symbol'] == '600001');
    expect(row['dividend_recent'], isTrue);
    expect(row['profit_ok'], isTrue);
    expect(row['revenue_ok'], isTrue);
    expect(row['lon_ok'], isTrue);
    // 换 key 即作废：v8 里那条 600009 不会被读进来
    expect(rows.any((item) => item['symbol'] == '600009'), isFalse);

    final restored = BandScanController(
      repository,
      nowFn: () => _today,
      fundamentals: fundamentals,
      lonCheck: lonCheck,
    );
    await restored.restore();
    expect(restored.status, BandScanStatus.done);
    expect(restored.hits.any((item) => item.symbol == '600009'), isFalse);
    final hit = restored.hits.firstWhere((item) => item.symbol == '600001');
    expect(hit.dividendRecent, isTrue);
    expect(hit.profitOk, isTrue);
    expect(hit.revenueOk, isTrue);
    expect(hit.lonOk, isTrue);
    restored.dispose();
  });

  test('新档位规则贯穿扫描：35%→一档、45%→二档、75%→三档', () async {
    final quotes = [
      _quote('600001', '甲股', price: 13.5), // pct 35 → 一档
      _quote('600002', '乙股', price: 14.5), // pct 45 → 二档（过 40 升档）
      _quote('600003', '丙股', price: 17.5), // pct 75 → 三档
    ];
    await setUpScan(
      {
        for (final q in quotes)
          q.symbol: const FundamentalsMarks(
              dividendRecent: true, profitOk: true, revenueOk: true),
      },
      lonResults: {for (final q in quotes) q.symbol: true},
      quoteOverride: quotes,
    );
    await controller.startScan();
    controller.setLimitUpFilter(false); // 测试数据无涨停，先放开

    final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
    expect(bySymbol['600001']!.group, 1);
    expect(bySymbol['600001']!.threshold, 20.0);
    expect(bySymbol['600002']!.group, 2);
    expect(bySymbol['600002']!.threshold, 40.0);
    expect(bySymbol['600003']!.group, 3);
    expect(bySymbol['600003']!.threshold, 70.0);
    expect(controller.groupCounts, {1: 1, 2: 1, 3: 1});
  });

  test('回落（fromTop）默认隐藏，「含回落」开关打开后并入列表', () async {
    // 收盘冲到 45%（二档）后现价 35%（一档区间）→ fromTop
    final quotes = [_quote('600001', '甲股')];
    await setUpScan(
      {
        '600001': const FundamentalsMarks(
            dividendRecent: true, profitOk: true, revenueOk: true),
      },
      lonResults: const {'600001': true},
      quoteOverride: quotes,
    );
    await store.upsertDailyBars('600001', _waveBars(closesPct: [20, 45, 45]));
    await controller.startScan();
    controller.setLimitUpFilter(false);

    final hit = controller.hits.single;
    expect(hit.group, 1);
    expect(hit.fromTop, isTrue);
    expect(controller.showFromTop, isFalse); // 默认隐藏
    expect(controller.visibleHits, isEmpty);

    controller.setShowFromTop(true);
    expect(controller.visibleHits, hasLength(1));
  });

  test('fundamentals 阶段并发补标记（不再逐只串行）', () async {
    // 20 只命中，每只假取数 20ms：串行要 ≥400ms，7 路并发 ≈ 60ms；
    // 用 inFlight 峰值直接证明是并发而不是串行
    final quotes = [
      for (var i = 1; i <= 20; i++)
        _quote('6000${i.toString().padLeft(2, '0')}', '股$i'),
    ];
    await setUpScan(
      {
        for (final q in quotes)
          q.symbol: const FundamentalsMarks(
              dividendRecent: true, profitOk: true, revenueOk: true),
      },
      lonResults: {for (final q in quotes) q.symbol: true},
      fundamentalsDelay: const Duration(milliseconds: 20),
      quoteOverride: quotes,
    );

    final startedAt = DateTime.now();
    await controller.startScan();
    final elapsed = DateTime.now().difference(startedAt);

    expect(controller.hits, hasLength(20));
    expect(fundamentals.requested.toSet(), quotes.map((q) => q.symbol).toSet());
    expect(fundamentals.maxInFlight, greaterThan(1), reason: '必须并发');
    expect(fundamentals.maxInFlight,
        lessThanOrEqualTo(fundamentalsFetchConcurrency));
    // 串行下限是 20×20ms=400ms，并发后应该远低于它
    expect(elapsed.inMilliseconds, lessThan(400));
    expect(controller.hits.every((hit) => hit.dividendRecent), isTrue);
  });

  test('lon 阶段并发校验（每只三周期，路数更保守）', () async {
    final quotes = [
      for (var i = 1; i <= 20; i++)
        _quote('6000${i.toString().padLeft(2, '0')}', '股$i'),
    ];
    await setUpScan(
      {
        for (final q in quotes)
          q.symbol: const FundamentalsMarks(
              dividendRecent: true, profitOk: true, revenueOk: true),
      },
      lonResults: {for (final q in quotes) q.symbol: true},
      lonDelay: const Duration(milliseconds: 20),
      quoteOverride: quotes,
    );

    final startedAt = DateTime.now();
    await controller.startScan();
    final elapsed = DateTime.now().difference(startedAt);

    expect(lonCheck.requested.toSet(), quotes.map((q) => q.symbol).toSet());
    expect(lonCheck.maxInFlight, greaterThan(1), reason: '必须并发');
    expect(lonCheck.maxInFlight, lessThanOrEqualTo(lonFetchConcurrency));
    expect(elapsed.inMilliseconds, lessThan(400));
    expect(controller.hits.every((hit) => hit.lonOk), isTrue);
  });

  group('本地日K缺失的补齐', () {
    const marks = FundamentalsMarks(
        dividendRecent: true, profitOk: true, revenueOk: true);

    test('扫描记录缺失股票代码并随结果持久化/恢复', () async {
      final quotes = [
        _quote('600001', '甲股'),
        _quote('600002', '乙股'),
        _quote('600003', '丙股'),
      ];
      await setUpScan(
        {for (final q in quotes) q.symbol: marks},
        lonResults: {for (final q in quotes) q.symbol: true},
        quoteOverride: quotes,
        withoutBars: {'600002', '600003'},
      );

      await controller.startScan();

      expect(controller.hits, hasLength(1)); // 只有 600001 参与判定
      expect(controller.skippedNoData, 2);
      expect(controller.skippedSymbols, ['600002', '600003']);

      final raw = await store.getState('band_scan:last:v9');
      final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
      expect(persisted['skipped_symbols'], ['600002', '600003']);

      final restored = BandScanController(repository,
          nowFn: () => _today,
          fundamentals: fundamentals,
          lonCheck: lonCheck);
      await restored.restore();
      expect(restored.skippedNoData, 2);
      expect(restored.skippedSymbols, ['600002', '600003']);
      restored.dispose();
    });

    test('补齐逐只补拉日K，完成后清空清单并给出重扫提示', () async {
      final quotes = [
        _quote('600001', '甲股'),
        _quote('600002', '乙股'),
      ];
      await setUpScan(
        {for (final q in quotes) q.symbol: marks},
        lonResults: {for (final q in quotes) q.symbol: true},
        quoteOverride: quotes,
        withoutBars: {'600002'},
      );
      await controller.startScan();
      expect(controller.skippedSymbols, ['600002']);

      await controller.backfillMissing();

      expect(sync.refreshed, ['600002']);
      expect(controller.backfilling, isFalse);
      expect(controller.backfillDone, 1);
      expect(controller.backfillTotal, 1);
      expect(controller.skippedSymbols, isEmpty);
      expect(controller.skippedNoData, 0);
      expect(controller.backfillNote, contains('已补齐 1 只'));
      // 补齐结果落盘，重进页面不会又冒出老提示
      final raw = await store.getState('band_scan:last:v9');
      final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
      expect(persisted['skipped_symbols'], isEmpty);
      expect(persisted['skipped_no_data'], 0);

      // 补齐后重扫：600002 已有日K，能参与判定
      await controller.startScan();
      expect(controller.hits.map((hit) => hit.symbol).toSet(),
          {'600001', '600002'});
      expect(controller.skippedNoData, 0);
    });

    test('单只补齐失败留在清单里，可以再点一次', () async {
      final quotes = [
        _quote('600001', '甲股'),
        _quote('600002', '乙股'),
        _quote('600003', '丙股'),
      ];
      await setUpScan(
        {for (final q in quotes) q.symbol: marks},
        lonResults: {for (final q in quotes) q.symbol: true},
        quoteOverride: quotes,
        withoutBars: {'600002', '600003'},
        backfillFailing: {'600003'},
      );
      await controller.startScan();

      await controller.backfillMissing();

      expect(controller.skippedSymbols, ['600003']);
      expect(controller.skippedNoData, 1);
      expect(controller.backfillNote, contains('1 只取数失败'));
      expect(controller.backfilling, isFalse);
    });

    test('补齐按 bandBackfillConcurrency 路并发', () async {
      final quotes = [
        for (var i = 1; i <= 20; i++)
          _quote('6000${i.toString().padLeft(2, '0')}', '股$i'),
      ];
      await setUpScan(
        {for (final q in quotes) q.symbol: marks},
        lonResults: {for (final q in quotes) q.symbol: true},
        quoteOverride: quotes,
        withoutBars: {for (final q in quotes) q.symbol},
        backfillDelay: const Duration(milliseconds: 20),
      );
      await controller.startScan();
      expect(controller.skippedNoData, 20);

      final startedAt = DateTime.now();
      await controller.backfillMissing();
      final elapsed = DateTime.now().difference(startedAt);

      expect(sync.refreshed, hasLength(20));
      expect(sync.maxInFlight, greaterThan(1), reason: '必须并发');
      expect(sync.maxInFlight, lessThanOrEqualTo(bandBackfillConcurrency));
      expect(elapsed.inMilliseconds, lessThan(400)); // 串行下限 20×20ms
      expect(controller.skippedSymbols, isEmpty);
    });

    test('没有缺失/扫描进行中时补齐是空操作', () async {
      await setUpScan({
        '600001': marks,
        '600002': marks,
        '600003': marks,
      }, lonResults: {
        '600001': true,
        '600002': true,
        '600003': true,
      });
      await controller.startScan();
      expect(controller.skippedSymbols, isEmpty);

      await controller.backfillMissing();
      expect(sync.refreshed, isEmpty);
      expect(controller.backfilling, isFalse);
      expect(controller.backfillNote, isNull);
    });
  });

  test('旧持久化数据缺 revenue_ok/lon_ok 字段 → 默认 false', () {
    final hit = BandHit.fromJson({
      'symbol': '600001',
      'price': 13.5,
      'low90': 10.0,
      'pct': 35.0,
      'group': 1,
      'threshold': 20.0,
      'over': 15.0,
      'max_pct': 35.0,
    });
    expect(hit.revenueOk, isFalse);
    expect(hit.lonOk, isFalse);
  });
}
