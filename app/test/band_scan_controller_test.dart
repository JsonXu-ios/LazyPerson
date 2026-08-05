/// 八档局扫描控制器的标记流程测试：扫描完成后逐只补
/// dividendRecent/profitOk/revenueOk（注入假基本面取数）、lonOk
/// （注入假 LON 校验）与 industry/concepts/hotSector（注入假板块取数），
/// 取数失败不影响扫描结果，
/// 五个展示层过滤开关对齐网页版 MoneyGrabPanel。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/fundamentals_service.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/lon_check_service.dart';
import 'package:lazyperson/data/market_repository.dart';
import 'package:lazyperson/data/providers/eastmoney_provider.dart';
import 'package:lazyperson/data/sector_service.dart';
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

/// 注入的假基本面取数：记录调用参数；映射里没有的股票视为取数失败
class _FakeFundamentals extends FundamentalsService {
  final Map<String, FundamentalsMarks> marks;
  final List<String> requested = [];
  final Map<String, double?> capsSeen = {};

  _FakeFundamentals(LocalStore store, this.marks) : super(store: store);

  @override
  Future<FundamentalsMarks> marksFor(String symbol, double? marketCapYi) async {
    requested.add(symbol);
    capsSeen[symbol] = marketCapYi;
    final found = marks[symbol];
    if (found == null) throw StateError('fetch failed: $symbol');
    return found;
  }
}

/// 注入的假 LON 校验：映射里没有的股票视为取数失败（保持默认 false）
class _FakeLonCheck extends LonCheckService {
  final Map<String, bool> results;
  final List<String> requested = [];

  _FakeLonCheck(LocalStore store, this.results) : super(store: store);

  @override
  Future<bool> lonOkFor(String symbol) async {
    requested.add(symbol);
    final found = results[symbol];
    if (found == null) throw StateError('lon failed: $symbol');
    return found;
  }
}

/// 注入的假板块取数：记录调用参数；映射里没有的股票视为取数失败。
/// [delay] 用来观察 sectorsOfMany 的并发度（inFlight 峰值）。
class _FakeSectors extends SectorService {
  final Map<String, StockSectors> results;
  final Set<String> hotCodes;
  final Duration delay;
  final List<String> requested = [];
  final List<Set<String>?> hotCodesSeen = [];
  int hotCodesCalls = 0;
  int inFlight = 0;
  int maxInFlight = 0;

  _FakeSectors(LocalStore store, this.results,
      {this.hotCodes = const {}, this.delay = Duration.zero})
      : super(store: store);

  @override
  Future<Set<String>> hotConceptCodes({int top = sectorHotTop}) async {
    hotCodesCalls += 1;
    return hotCodes;
  }

  @override
  Future<StockSectors> sectorsOf(String symbol, {Set<String>? hotCodes}) async {
    requested.add(symbol);
    hotCodesSeen.add(hotCodes);
    inFlight += 1;
    maxInFlight = math.max(maxInFlight, inFlight);
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      final found = results[symbol];
      if (found == null) throw StateError('sector failed: $symbol');
      return found;
    } finally {
      inFlight -= 1;
    }
  }
}

final _today = DateTime(2026, 7, 24); // 周五

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
      price: price, // 默认 13.5：相对低点 10 涨 35% → 一档、非强信号
      preClose: 13.0,
      marketCap: 100.0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late MarketRepository repository;
  late _FakeFundamentals fundamentals;
  late _FakeLonCheck lonCheck;
  late _FakeSectors sectors;
  late BandScanController controller;

  Future<void> setUpScan(Map<String, FundamentalsMarks> marks,
      {Map<String, bool> lonResults = const {},
      Map<String, StockSectors> sectorResults = const {},
      Set<String> hotCodes = const {},
      Duration sectorDelay = Duration.zero,
      List<Quote>? quoteOverride}) async {
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
    repository = MarketRepository(
      store: store,
      sync: SyncService(store: store, eastmoney: _FakeEastmoney(quotes)),
    );
    await store.setState('initial_sync_done', '1');
    for (final quote in quotes) {
      await store.upsertDailyBars(quote.symbol, _waveBars());
    }
    fundamentals = _FakeFundamentals(store, marks);
    lonCheck = _FakeLonCheck(store, lonResults);
    sectors = _FakeSectors(store, sectorResults,
        hotCodes: hotCodes, delay: sectorDelay);
    controller = BandScanController(
      repository,
      nowFn: () => _today,
      fundamentals: fundamentals,
      lonCheck: lonCheck,
      sectors: sectors,
    );
  }

  tearDown(() => store.close());

  test('扫描完成后逐只补标记；取数失败的股票保持默认 false 且不影响扫描结果', () async {
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

  test('标记随结果持久化（key v8），当日 restore 恢复', () async {
    await setUpScan({
      '600001': const FundamentalsMarks(
          dividendRecent: true, profitOk: true, revenueOk: true),
    }, lonResults: {
      '600001': true,
    });
    await controller.startScan();

    final raw = await store.getState('band_scan:last:v8');
    expect(raw, isNotNull);
    final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
    final rows = (persisted['hits'] as List).cast<Map>();
    final row = rows.firstWhere((item) => item['symbol'] == '600001');
    expect(row['dividend_recent'], isTrue);
    expect(row['profit_ok'], isTrue);
    expect(row['revenue_ok'], isTrue);
    expect(row['lon_ok'], isTrue);

    final restored = BandScanController(
      repository,
      nowFn: () => _today,
      fundamentals: fundamentals,
      lonCheck: lonCheck,
    );
    await restored.restore();
    expect(restored.status, BandScanStatus.done);
    final hit = restored.hits.firstWhere((item) => item.symbol == '600001');
    expect(hit.dividendRecent, isTrue);
    expect(hit.profitOk, isTrue);
    expect(hit.revenueOk, isTrue);
    expect(hit.lonOk, isTrue);
    restored.dispose();
  });

  group('强信号（strong）', () {
    const marks = FundamentalsMarks(
        dividendRecent: true, profitOk: true, revenueOk: true);

    /// 甲=45%（过40强信号）、乙=35%（一档非强）、丙=75%（二档，未过70? 75≥70 强）
    List<Quote> strongQuotes() => [
          _quote('600001', '甲股', price: 14.5), // pct 45 → 1档 强
          _quote('600002', '乙股', price: 13.5), // pct 35 → 1档 非强
          _quote('600003', '丙股', price: 16.6), // pct 66 → 2档 非强（未过70）
        ];

    test('evaluateStock 的 strong 标记贯穿扫描/筛选/持久化（v8）', () async {
      final quotes = strongQuotes();
      await setUpScan(
        {for (final q in quotes) q.symbol: marks},
        lonResults: {for (final q in quotes) q.symbol: true},
        quoteOverride: quotes,
      );
      await controller.startScan();
      controller.setLimitUpFilter(false); // 测试数据无涨停，先放开

      final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
      expect(bySymbol['600001']!.group, 1);
      expect(bySymbol['600001']!.strong, isTrue);
      expect(bySymbol['600002']!.group, 1);
      expect(bySymbol['600002']!.strong, isFalse);
      expect(bySymbol['600003']!.group, 2);
      expect(bySymbol['600003']!.strong, isFalse);

      // 默认关 → 不过滤
      expect(controller.strongFilter, isFalse);
      expect(controller.visibleHits, hasLength(3));

      controller.setStrongFilter(true);
      expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);

      // 与其他开关取交集（&& 语义）
      controller.setNorthFilter(true);
      expect(controller.visibleHits.where((hit) => !hit.northOk), isEmpty);
      controller.setNorthFilter(false);
      controller.setStrongFilter(false);
      expect(controller.visibleHits, hasLength(3));

      // 持久化 key 升到 v8，strong 随行落盘
      expect(await store.getState('band_scan:last:v7'), isNull);
      final raw = await store.getState('band_scan:last:v8');
      final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
      final rows = (persisted['hits'] as List).cast<Map>();
      expect(rows.firstWhere((r) => r['symbol'] == '600001')['strong'], isTrue);
      expect(
          rows.firstWhere((r) => r['symbol'] == '600002')['strong'], isFalse);

      // 当日 restore 把 strong 带回来
      final restored = BandScanController(repository,
          nowFn: () => _today,
          fundamentals: fundamentals,
          lonCheck: lonCheck,
          sectors: sectors);
      await restored.restore();
      expect(
          restored.hits.firstWhere((h) => h.symbol == '600001').strong, isTrue);
      expect(restored.hits.firstWhere((h) => h.symbol == '600002').strong,
          isFalse);
      restored.dispose();
    });

    test('v7 旧结果不再被 v8 读到（换 key 即作废）', () async {
      final quotes = strongQuotes();
      await setUpScan(
        {for (final q in quotes) q.symbol: marks},
        lonResults: {for (final q in quotes) q.symbol: true},
        quoteOverride: quotes,
      );
      await store.setState(
        'band_scan:last:v7',
        jsonEncode({
          'trade_date': _today.toIso8601String().substring(0, 10),
          'total': 1,
          'hits': [
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
      await controller.restore();
      expect(controller.status, BandScanStatus.idle);
      expect(controller.hits, isEmpty);
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

  group('板块标记（sector 阶段）', () {
    const marks = {
      '600001': FundamentalsMarks(
          dividendRecent: true, profitOk: true, revenueOk: true),
      '600002': FundamentalsMarks(
          dividendRecent: true, profitOk: true, revenueOk: true),
      '600003': FundamentalsMarks(
          dividendRecent: true, profitOk: true, revenueOk: true),
    };
    const lonAll = {'600001': true, '600002': true, '600003': true};

    test('扫描完成后逐只补行业/概念/热点；取数失败保持默认空值', () async {
      await setUpScan(marks, lonResults: lonAll, sectorResults: {
        '600001': const StockSectors(
          symbol: '600001',
          industry: '白酒Ⅱ',
          concepts: ['酿酒概念', '茅指数'],
          hotConcepts: ['酿酒概念'],
        ),
        '600003': const StockSectors(
          symbol: '600003',
          industry: '半导体',
          concepts: ['国产芯片'],
        ),
        // 600002 缺失 → sectorsOf 抛异常，模拟取数失败
      }, hotCodes: {
        'BK0477'
      });

      await controller.startScan();

      expect(controller.status, BandScanStatus.done);
      expect(controller.stage, '');
      // 只对命中的股票取数
      expect(sectors.requested.toSet(), {'600001', '600002', '600003'});
      // 热点概念榜只取一次，复用给所有命中（不是每只都重拉）
      expect(sectors.hotCodesCalls, 1);
      expect(sectors.hotCodesSeen.every((seen) => seen?.contains('BK0477') == true),
          isTrue);

      final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
      expect(bySymbol['600001']!.industry, '白酒Ⅱ');
      expect(bySymbol['600001']!.concepts, ['酿酒概念', '茅指数']);
      expect(bySymbol['600001']!.hotSector, isTrue);
      expect(bySymbol['600003']!.industry, '半导体');
      expect(bySymbol['600003']!.concepts, ['国产芯片']);
      expect(bySymbol['600003']!.hotSector, isFalse); // 概念不在热点榜
      // 取数失败 → 默认空/false，且不影响扫描结果
      expect(bySymbol['600002']!.industry, '');
      expect(bySymbol['600002']!.concepts, isEmpty);
      expect(bySymbol['600002']!.hotSector, isFalse);
      expect(controller.hits, hasLength(3));
    });

    test('概念最多留 6 个（对齐 backend concepts[:6]）', () async {
      await setUpScan(marks, lonResults: lonAll, sectorResults: {
        '600001': const StockSectors(
          symbol: '600001',
          concepts: ['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8'],
        ),
      });
      await controller.startScan();
      final hit = controller.hits.firstWhere((row) => row.symbol == '600001');
      expect(hit.concepts, ['c1', 'c2', 'c3', 'c4', 'c5', 'c6']);
    });

    test('热点榜取不到 → 只补行业/概念，hotSector 保持 false', () async {
      await setUpScan(marks, lonResults: lonAll, sectorResults: {
        '600001': const StockSectors(
          symbol: '600001',
          industry: '白酒Ⅱ',
          concepts: ['酿酒概念'],
          // hotConcepts 为空 → hot=false
        ),
      });
      await controller.startScan();
      final hit = controller.hits.firstWhere((row) => row.symbol == '600001');
      expect(hit.industry, '白酒Ⅱ');
      expect(hit.hotSector, isFalse);
    });

    test('「热点板块」是展示层过滤（默认关），与其他开关取交集', () async {
      await setUpScan(marks, lonResults: {
        '600001': true,
        '600002': false,
        '600003': true,
      }, sectorResults: {
        '600001': const StockSectors(
            symbol: '600001', concepts: ['酿酒概念'], hotConcepts: ['酿酒概念']),
        '600002': const StockSectors(
            symbol: '600002', concepts: ['MLCC'], hotConcepts: ['MLCC']),
        '600003': const StockSectors(symbol: '600003', concepts: ['国产芯片']),
      });
      await controller.startScan();
      controller.setLimitUpFilter(false); // 测试数据无涨停，先放开

      expect(controller.hotFilter, isFalse); // 默认关
      expect(controller.visibleHits, hasLength(3));

      controller.setHotFilter(true);
      expect(controller.visibleHits.map((hit) => hit.symbol).toSet(),
          {'600001', '600002'});

      // 与 LON 开关取交集（&& 语义对齐 MoneyGrabPanel.visibleHits）
      controller.setLonFilter(true);
      expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);

      controller.setHotFilter(false);
      expect(controller.visibleHits.map((hit) => hit.symbol).toSet(),
          {'600001', '600003'});
    });

    test('板块标记随结果持久化（v8），当日 restore 恢复', () async {
      await setUpScan(marks, lonResults: lonAll, sectorResults: {
        '600001': const StockSectors(
          symbol: '600001',
          industry: '白酒Ⅱ',
          concepts: ['酿酒概念', '茅指数'],
          hotConcepts: ['酿酒概念'],
        ),
      });
      await controller.startScan();

      final raw = await store.getState('band_scan:last:v8');
      final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
      final rows = (persisted['hits'] as List).cast<Map>();
      final row = rows.firstWhere((item) => item['symbol'] == '600001');
      expect(row['industry'], '白酒Ⅱ');
      expect(row['concepts'], ['酿酒概念', '茅指数']);
      expect(row['hot_sector'], isTrue);

      final restored = BandScanController(
        repository,
        nowFn: () => _today,
        fundamentals: fundamentals,
        lonCheck: lonCheck,
        sectors: sectors,
      );
      await restored.restore();
      final hit = restored.hits.firstWhere((item) => item.symbol == '600001');
      expect(hit.industry, '白酒Ⅱ');
      expect(hit.concepts, ['酿酒概念', '茅指数']);
      expect(hit.hotSector, isTrue);
      restored.dispose();
    });

    test('sector 阶段并发补标记（不再逐只串行）', () async {
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
        sectorResults: {
          for (final q in quotes)
            q.symbol: StockSectors(symbol: q.symbol, industry: '白酒Ⅱ'),
        },
        sectorDelay: const Duration(milliseconds: 20),
        quoteOverride: quotes,
      );

      final startedAt = DateTime.now();
      await controller.startScan();
      final elapsed = DateTime.now().difference(startedAt);

      expect(controller.hits, hasLength(20));
      expect(sectors.requested.toSet(), quotes.map((q) => q.symbol).toSet());
      expect(sectors.maxInFlight, greaterThan(1), reason: '必须并发');
      expect(sectors.maxInFlight, lessThanOrEqualTo(sectorFetchConcurrency));
      // 串行下限是 20×20ms=400ms，并发后应该远低于它
      expect(elapsed.inMilliseconds, lessThan(400));
      expect(controller.hits.every((hit) => hit.industry == '白酒Ⅱ'), isTrue);
    });

    test('旧持久化数据缺 industry/concepts/hot_sector → 默认空/false', () {
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
      expect(hit.industry, '');
      expect(hit.concepts, isEmpty);
      expect(hit.hotSector, isFalse);
    });
  });
}
