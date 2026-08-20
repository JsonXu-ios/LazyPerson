/// 八档局扫描控制器测试。
///
/// 核心约束（任务 A）：**扫描是纯本地的** —— 只有一次全市场快照请求，
/// fundamentals/LON 阶段不再联网，缓存里没有的标记是"未知"（null）第三态；
/// 要补数据必须显式调 enrichMarks（「补充数据 N 只」按钮）。
///
/// 另外覆盖：换手/3日/5日三个新筛选（任务 B）、展示层过滤开关的三态语义、
/// 本地日K缺失的一键补齐。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/fundamentals_service.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/lon_check_service.dart';
import 'package:lazyperson/data/market_repository.dart';
import 'package:lazyperson/data/popularity_service.dart';
import 'package:lazyperson/data/providers/eastmoney_provider.dart';
import 'package:lazyperson/data/sync_service.dart';
import 'package:lazyperson/logic/band_scanner.dart';
import 'package:lazyperson/models/models.dart';
import 'package:lazyperson/state/band_scan_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _today = DateTime(2026, 7, 24); // 周五
final _todayText = _today.toIso8601String().substring(0, 10);

class _FakeEastmoney extends EastmoneyProvider {
  final List<Quote> quotes;
  int snapshotCalls = 0;

  _FakeEastmoney(this.quotes);

  @override
  Future<List<Quote>> fullMarketSnapshot(
      {void Function(int loaded, int total)? onProgress}) async {
    snapshotCalls += 1;
    return quotes;
  }
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

  _FakeFundamentals(LocalStore store, this.marks, {this.delay = Duration.zero})
      : super(store: store, nowFn: (() => _today));

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

/// 注入的假 LON 校验：映射里没有的股票抛错（= 取数失败 → 未知）。
class _FakeLonCheck extends LonCheckService {
  final Map<String, bool> results;
  final Duration delay;
  final List<String> requested = [];
  int inFlight = 0;
  int maxInFlight = 0;

  _FakeLonCheck(LocalStore store, this.results, {this.delay = Duration.zero})
      : super(store: store, nowFn: (() => _today));

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

/// 假同步服务：refreshSymbol 把 90 天日K写进本地库（模拟补齐成功），
/// [failing] 里的股票抛错（模拟单只补齐失败）
class _FakeSync extends SyncService {
  final Set<String> failing;
  /// 这些股票 refresh 成功，但数据源本身只有几根（次新股/长期停牌）
  final Set<String> shortData;
  final Duration delay;
  final List<String> refreshed = [];
  int inFlight = 0;
  int maxInFlight = 0;

  _FakeSync({
    required super.store,
    required EastmoneyProvider eastmoney,
    this.failing = const {},
    this.shortData = const {},
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
      await store.upsertDailyBars(
        symbol,
        shortData.contains(symbol) ? _waveBars().take(5).toList() : _waveBars(),
      );
    } finally {
      inFlight -= 1;
    }
  }
}

/// 200 天日线：平台 + 波段低点 + 尾部按 closesPct 相对低点的涨幅收盘
List<KlineBar> _waveBars(
    {double low = 10.0, List<double> closesPct = const [5, 12, 32]}) {
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

Quote _quote(String symbol, String name,
        {double price = 13.5, double? turnover}) =>
    Quote(
      symbol: symbol,
      market: 'SH',
      name: name,
      price: price, // 默认 13.5：相对低点 10 涨 35% → 一档
      preClose: 13.0,
      marketCap: 100.0,
      turnover: turnover,
    );

/// 假人气榜：不打网络，直接给代码集合；[failing] 时抛错（模拟榜单拿不到）
class _FakePopularity extends PopularityService {
  final Set<String> symbols;
  final bool failing;
  int calls = 0;

  _FakePopularity(LocalStore store, MarketRepository repository, this.symbols,
      {this.failing = false})
      : super(store: store, sectors: repository.sectors);

  @override
  Future<Set<String>> topSymbols({int limit = 100}) async {
    calls += 1;
    if (failing) throw StateError('rank down');
    return symbols;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late MarketRepository repository;
  late _FakeSync sync;
  late _FakeEastmoney eastmoney;
  late _FakeFundamentals fundamentals;
  late _FakeLonCheck lonCheck;
  late BandScanController controller;

  Future<void> setUpScan(Map<String, FundamentalsMarks> marks,
      {Map<String, bool> lonResults = const {},
      Duration fundamentalsDelay = Duration.zero,
      Duration lonDelay = Duration.zero,
      Duration backfillDelay = Duration.zero,
      Set<String> backfillFailing = const {},
      Set<String> backfillShortData = const {},
      List<Quote>? quoteOverride,
      bool autoComplete = false,
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
    eastmoney = _FakeEastmoney(quotes);
    sync = _FakeSync(
      store: store,
      eastmoney: eastmoney,
      failing: backfillFailing,
      shortData: backfillShortData,
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
      autoComplete: autoComplete,
    );
  }

  /// 直接往缓存里塞标记（模拟"上次补过数据"）
  Future<void> seedFundamentalsCache(String symbol, FundamentalsMarks marks) =>
      store.setState(
        '$fundStatePrefix$symbol',
        jsonEncode({
          'checked_at': _todayText,
          'dividend_recent': marks.dividendRecent,
          'profit_ok': marks.profitOk,
          'revenue_ok': marks.revenueOk,
        }),
      );

  Future<void> seedLonCache(String symbol, bool ok) => store.setState(
        '$lonResultPrefix$symbol',
        jsonEncode({'checked_at': _todayText, 'lon_ok': ok}),
      );

  const marksAllTrue =
      FundamentalsMarks(dividendRecent: true, profitOk: true, revenueOk: true);

  tearDown(() => store.close());

  group('扫描纯本地（任务 A）', () {
    test('扫描期间不发基本面/LON 请求，缓存缺失的标记是"未知"而不是 false', () async {
      await setUpScan({'600001': marksAllTrue}, lonResults: {'600001': true});

      await controller.startScan();

      expect(controller.status, BandScanStatus.done);
      expect(controller.stage, '');
      expect(controller.hits, hasLength(3));
      // 唯一的网络请求：全市场快照
      expect(eastmoney.snapshotCalls, 1);
      expect(fundamentals.requested, isEmpty, reason: '扫描不许拉基本面');
      expect(lonCheck.requested, isEmpty, reason: '扫描不许拉 LON');

      for (final hit in controller.hits) {
        expect(hit.dividendRecent, isNull);
        expect(hit.profitOk, isNull);
        expect(hit.revenueOk, isNull);
        expect(hit.lonOk, isNull);
        expect(hit.marksKnown, isFalse);
      }
      expect(controller.unknownMarkCount, 3);
      expect(controller.unknownMarkSymbols.toSet(),
          {'600001', '600002', '600003'});
    });

    test('缓存里已有的标记直接被扫描采用，且不产生请求', () async {
      await setUpScan(const {});
      await seedFundamentalsCache(
        '600001',
        const FundamentalsMarks(
            dividendRecent: true, profitOk: false, revenueOk: true),
      );
      await seedLonCache('600001', true);
      await seedLonCache('600002', false);

      await controller.startScan();

      final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
      expect(bySymbol['600001']!.dividendRecent, isTrue);
      expect(bySymbol['600001']!.profitOk, isFalse);
      expect(bySymbol['600001']!.revenueOk, isTrue);
      expect(bySymbol['600001']!.lonOk, isTrue);
      expect(bySymbol['600001']!.marksKnown, isTrue);
      // 只有 LON 有缓存 → 基本面仍未知
      expect(bySymbol['600002']!.lonOk, isFalse);
      expect(bySymbol['600002']!.dividendRecent, isNull);
      expect(bySymbol['600002']!.marksKnown, isFalse);
      expect(bySymbol['600003']!.marksKnown, isFalse);
      expect(controller.unknownMarkCount, 2);
      expect(fundamentals.requested, isEmpty);
      expect(lonCheck.requested, isEmpty);
    });

    test('过期的缓存按未知处理（不当成 false）', () async {
      await setUpScan(const {});
      // 基本面缓存 3 天有效、LON 1 天有效：都塞一个更早的日期
      await store.setState(
        '${fundStatePrefix}600001',
        jsonEncode({
          'checked_at': '2026-07-10',
          'dividend_recent': true,
          'profit_ok': true,
          'revenue_ok': true,
        }),
      );
      await store.setState(
        '${lonResultPrefix}600001',
        jsonEncode({'checked_at': '2026-07-10', 'lon_ok': true}),
      );

      await controller.startScan();

      final hit =
          controller.hits.firstWhere((item) => item.symbol == '600001');
      expect(hit.dividendRecent, isNull);
      expect(hit.lonOk, isNull);
    });

    test('命中行带上快照的换手率与市值、本地算的 3/5 日涨幅', () async {
      await setUpScan(const {}, quoteOverride: [
        _quote('600001', '甲股', turnover: 4.2),
        _quote('600002', '乙股'), // 快照没给换手率
      ]);

      await controller.startScan();

      final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
      expect(bySymbol['600001']!.turnover, 4.2);
      expect(bySymbol['600001']!.marketCap, 100.0);
      expect(bySymbol['600002']!.turnover, isNull);
      // 窗口最后一根就是今天 → 基准取 closes[-4]（平台价 10.6）
      expect(bySymbol['600001']!.chg3, closeTo(27.36, 0.01));
      expect(bySymbol['600001']!.chg5, closeTo(27.36, 0.01));
    });
  });

  group('扫描后自动补数据（用户不用点按钮）', () {
    test('扫完自动补日K与基本面/LON；补不出来的进黑名单，下次扫描不再计入缺失',
        () async {
      await setUpScan(
        {
          '600001': const FundamentalsMarks(
              dividendRecent: true, profitOk: true, revenueOk: true),
          '600002': const FundamentalsMarks(
              dividendRecent: false, profitOk: true, revenueOk: false),
        },
        lonResults: {'600001': true, '600002': false},
        quoteOverride: [_quote('600001', '甲股'), _quote('600002', '乙股')],
        withoutBars: {'600002'},
        backfillShortData: {'600002'}, // 补回来也不足 20 根 → 黑名单
        autoComplete: true,
      );

      await controller.startScan();
      // 自动补数据是后台任务，等它跑完
      await Future<void>.delayed(const Duration(milliseconds: 60));

      // 日K补齐已自动跑过，且 600002 进了黑名单
      expect(sync.refreshed, contains('600002'));
      expect(controller.unfixableCount, 1);
      final raw = await store.getState(noDataBlacklistKey);
      expect(jsonDecode(raw!), contains('600002'));

      // 基本面/LON 也自动补了：命中股标记不再是未知
      expect(controller.unknownMarkCount, 0);
      expect(fundamentals.requested, contains('600001'));

      // 再扫一次：黑名单里的不再计入"本地日K缺失"
      await controller.startScan();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controller.skippedNoData, 0);
      expect(controller.skippedSymbols, isEmpty);
    });

    test('恢复当天结果后，上次没补完的接着补（重开 App 不用重新扫描）', () async {
      // 第一轮：基本面取数全失败 → 标记留在"未知"，随结果一起持久化
      await setUpScan(<String, FundamentalsMarks>{},
          lonResults: <String, bool>{}, autoComplete: true);
      await controller.startScan();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(controller.unknownMarkCount, greaterThan(0));

      // 数据源恢复正常后重开 App：restore 自己把剩下的补上
      fundamentals.marks.addAll({
        for (final hit in controller.hits) hit.symbol: marksAllTrue,
      });
      lonCheck.results.addAll({
        for (final hit in controller.hits) hit.symbol: true,
      });
      final restored = BandScanController(repository,
          nowFn: () => _today,
          fundamentals: fundamentals,
          lonCheck: lonCheck,
          autoComplete: true);
      await restored.restore();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(restored.unknownMarkCount, 0);
      restored.dispose();
    });
  });

  group('补充数据（enrichMarks）', () {
    test('只对未知的股票取数，失败的保持未知可再点一次', () async {
      await setUpScan({
        '600001': marksAllTrue,
        '600003': const FundamentalsMarks(
            dividendRecent: false, profitOk: true, revenueOk: false),
        // 600002 缺失 → marksFor 抛异常，模拟取数失败
      }, lonResults: {
        '600001': true,
        '600003': false,
        // 600002 缺失 → lonOkFor 抛异常
      });
      // 600003 的 LON 已有缓存 → 补充阶段不该再拉它
      await seedLonCache('600003', false);
      await controller.startScan();
      expect(controller.unknownMarkCount, 3);

      await controller.enrichMarks();

      expect(controller.enriching, isFalse);
      expect(fundamentals.requested.toSet(), {'600001', '600002', '600003'});
      expect(lonCheck.requested.toSet(), {'600001', '600002'});
      expect(fundamentals.capsSeen['600001'], 100.0);

      final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
      expect(bySymbol['600001']!.dividendRecent, isTrue);
      expect(bySymbol['600001']!.profitOk, isTrue);
      expect(bySymbol['600001']!.revenueOk, isTrue);
      expect(bySymbol['600001']!.lonOk, isTrue);
      expect(bySymbol['600001']!.marksKnown, isTrue);
      // 取数失败 → 仍是未知（不是 false），可再点一次
      expect(bySymbol['600002']!.dividendRecent, isNull);
      expect(bySymbol['600002']!.lonOk, isNull);
      expect(bySymbol['600003']!.dividendRecent, isFalse);
      expect(bySymbol['600003']!.profitOk, isTrue);
      expect(bySymbol['600003']!.lonOk, isFalse);

      expect(controller.unknownMarkCount, 1);
      expect(controller.enrichNote, contains('仍未知'));
      expect(controller.enrichDone, controller.enrichTotal);
    });

    test('全部补齐后结果落盘，重进页面直接是已知标记', () async {
      await setUpScan(
        {'600001': marksAllTrue},
        lonResults: const {'600001': true},
        quoteOverride: [_quote('600001', '甲股')],
      );
      await controller.startScan();
      await controller.enrichMarks();

      expect(controller.unknownMarkCount, 0);
      expect(controller.enrichNote, contains('已补充'));

      final raw = await store.getState('band_scan:last:v12');
      final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
      final row = (persisted['hits'] as List).cast<Map>().single;
      expect(row['dividend_recent'], isTrue);
      expect(row['lon_ok'], isTrue);

      final restored = BandScanController(repository,
          nowFn: () => _today,
          fundamentals: fundamentals,
          lonCheck: lonCheck,
          autoComplete: false);
      await restored.restore();
      expect(restored.hits.single.marksKnown, isTrue);
      expect(restored.unknownMarkCount, 0);
      restored.dispose();
    });

    test('补充数据按 worker 池并发（基本面 + LON 两段）', () async {
      final quotes = [
        for (var i = 1; i <= 20; i++)
          _quote('6000${i.toString().padLeft(2, '0')}', '股$i'),
      ];
      await setUpScan(
        {for (final q in quotes) q.symbol: marksAllTrue},
        lonResults: {for (final q in quotes) q.symbol: true},
        fundamentalsDelay: const Duration(milliseconds: 20),
        lonDelay: const Duration(milliseconds: 20),
        quoteOverride: quotes,
      );
      await controller.startScan();

      final startedAt = DateTime.now();
      await controller.enrichMarks();
      final elapsed = DateTime.now().difference(startedAt);

      expect(fundamentals.maxInFlight, greaterThan(1), reason: '必须并发');
      expect(fundamentals.maxInFlight,
          lessThanOrEqualTo(fundamentalsFetchConcurrency));
      expect(lonCheck.maxInFlight, greaterThan(1), reason: '必须并发');
      expect(lonCheck.maxInFlight, lessThanOrEqualTo(lonFetchConcurrency));
      // 串行下限是 (20+20)×20ms=800ms，并发后应该远低于它
      expect(elapsed.inMilliseconds, lessThan(800));
      expect(controller.unknownMarkCount, 0);
      expect(controller.hits.every((hit) => hit.dividendRecent == true), isTrue);
      expect(controller.hits.every((hit) => hit.lonOk == true), isTrue);
    });

    test('没有未知标记时补充是空操作', () async {
      await setUpScan(const {}, quoteOverride: [_quote('600001', '甲股')]);
      await seedFundamentalsCache('600001', marksAllTrue);
      await seedLonCache('600001', true);
      await controller.startScan();
      expect(controller.unknownMarkCount, 0);

      await controller.enrichMarks();
      expect(fundamentals.requested, isEmpty);
      expect(lonCheck.requested, isEmpty);
      expect(controller.enrichNote, isNull);
    });
  });

  group('展示层筛选', () {
    test('分红/净利润/估市值/LON 默认关；勾选后未知的一律不显示', () async {
      await setUpScan(const {});
      await seedFundamentalsCache('600001', marksAllTrue);
      await seedFundamentalsCache(
        '600002',
        const FundamentalsMarks(
            dividendRecent: true, profitOk: false, revenueOk: true),
      );
      await seedLonCache('600001', true);
      // 600003 什么缓存都没有 → 全未知
      await controller.startScan();
      controller.setLimitUpFilter(false); // 测试数据无涨停，先放开
      controller.setSwingFilter(false); // fixture 波段高 35%，先放开

      expect(controller.dividendFilter, isFalse);
      expect(controller.profitFilter, isFalse);
      expect(controller.revenueFilter, isFalse);
      expect(controller.lonFilter, isFalse);
      expect(controller.visibleHits, hasLength(3));
      expect(controller.markFilterActive, isFalse);

      controller.setDividendFilter(true);
      expect(controller.markFilterActive, isTrue);
      // 600003 未知 → 不显示（不当成 false，但也不显示）
      expect(controller.visibleHits.map((hit) => hit.symbol).toSet(),
          {'600001', '600002'});

      controller.setDividendFilter(false);
      controller.setProfitFilter(true);
      expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);

      controller.setProfitFilter(false);
      controller.setLonFilter(true);
      expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);
    });

    test('换手/3日/5日三个新开关（任务 B）', () async {
      await setUpScan(const {}, quoteOverride: [
        _quote('600001', '甲股', turnover: 4.2), // 换手达标
        _quote('600002', '乙股', turnover: 1.1), // 换手不达标
        _quote('600003', '丙股'), // 快照没给换手率 → null
      ]);
      await controller.startScan();
      controller.setLimitUpFilter(false);
      controller.setSwingFilter(false);

      expect(controller.turnoverFilter, isFalse);
      expect(controller.chg3Filter, isFalse);
      expect(controller.chg5Filter, isFalse);
      expect(controller.visibleHits, hasLength(3));

      controller.setTurnoverFilter(true);
      // null 的被过滤掉（数据缺失不算达标）
      expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);

      controller.setTurnoverFilter(false);
      // 三只的 3/5 日涨幅都是 27.36% > 7% / 14%
      controller.setChg3Filter(true);
      expect(controller.visibleHits, hasLength(3));
      controller.setChg5Filter(true);
      expect(controller.visibleHits, hasLength(3));
    });

    test('3 日不达标 / 5 日达标时两个开关各自生效', () async {
      // 尾部 5 根收盘 12.5→12.9：3 日基准 12.6（涨 3.2%，不到 7%），
      // 5 日基准 10.6（涨 22.6%，超过 14%）
      await setUpScan(const {}, quoteOverride: [
        _quote('600001', '甲股', price: 13.0),
      ]);
      await store.upsertDailyBars(
          '600001', _waveBars(closesPct: [25, 26, 27, 28, 29]));
      await controller.startScan();
      controller.setLimitUpFilter(false);
      controller.setSwingFilter(false);

      final hit = controller.hits.single;
      expect(hit.chg3, closeTo(3.17, 0.01));
      expect(hit.chg5, closeTo(22.64, 0.01));

      controller.setChg5Filter(true);
      expect(controller.visibleHits, hasLength(1));
      controller.setChg3Filter(true);
      expect(controller.visibleHits, isEmpty); // 3 日不达标被过滤
    });

    test('波动≥40% 默认开：90 日内从 0% 起没涨到过 40% 的去掉', () async {
      await setUpScan(const {}, quoteOverride: [
        _quote('600001', '没动过', price: 13.5), // 波段高 35%，现价 35%
        _quote('600002', '动过的', price: 13.5), // 曾冲到 45% 再回到 35%
      ]);
      await store.upsertDailyBars('600002', _waveBars(closesPct: [20, 45, 35]));
      await controller.startScan();
      controller.setLimitUpFilter(false);
      controller.setShowFromTop(true); // 600002 是回落形态，先并进来

      expect(controller.swingFilter, isTrue);
      final peaks = {for (final hit in controller.hits) hit.symbol: hit.maxPct};
      expect(peaks['600001'], lessThan(40));
      expect(peaks['600002'], greaterThanOrEqualTo(40));
      // 默认开：只剩真正动过的那只
      expect(controller.visibleHits.map((hit) => hit.symbol), ['600002']);

      controller.setSwingFilter(false);
      expect(controller.visibleHits, hasLength(2));
    });

    test('人气股开关：打开时才拉榜单，只留榜上的；榜单拿不到一只都不显示', () async {
      await setUpScan(const {}, quoteOverride: [
        _quote('600001', '甲股'),
        _quote('600002', '乙股'),
        _quote('600003', '丙股'),
      ]);
      final popularity = _FakePopularity(store, repository, {'600002', '000999'});
      final scan = BandScanController(repository,
          nowFn: () => _today,
          fundamentals: fundamentals,
          lonCheck: lonCheck,
          popularity: popularity,
          autoComplete: false);
      await scan.startScan();
      scan.setLimitUpFilter(false);
      scan.setSwingFilter(false);

      expect(scan.popularFilter, isFalse);
      expect(popularity.calls, 0); // 没打开就不拉榜单
      expect(scan.visibleHits, hasLength(3));

      scan.setPopularFilter(true);
      await Future<void>.delayed(Duration.zero); // 等榜单回来
      expect(popularity.calls, 1);
      expect(scan.popularSymbols, {'600002', '000999'});
      expect(scan.visibleHits.map((hit) => hit.symbol), ['600002']);

      // 关了再开：榜单已有，不重拉
      scan.setPopularFilter(false);
      scan.setPopularFilter(true);
      expect(popularity.calls, 1);
      scan.dispose();

      // 榜单拿不到：开关开着但一只都不显示（宁可漏也不乱给）
      final broken = BandScanController(repository,
          nowFn: () => _today,
          fundamentals: fundamentals,
          lonCheck: lonCheck,
          popularity: _FakePopularity(store, repository, {}, failing: true),
          autoComplete: false);
      await broken.startScan();
      broken.setLimitUpFilter(false);
      broken.setSwingFilter(false);
      broken.setPopularFilter(true);
      await Future<void>.delayed(Duration.zero);
      expect(broken.popularSymbols, isNull);
      expect(broken.visibleHits, isEmpty);
      broken.dispose();
    });

    test('回落（fromTop）默认隐藏，「含回落」开关打开后并入列表', () async {
      // 收盘冲到 45%（二档）后现价 35%（一档区间）→ fromTop
      await setUpScan(const {}, quoteOverride: [_quote('600001', '甲股')]);
      await store.upsertDailyBars('600001', _waveBars(closesPct: [20, 45, 45]));
      await controller.startScan();
      controller.setLimitUpFilter(false);
      controller.setSwingFilter(false);

      final hit = controller.hits.single;
      expect(hit.group, 1);
      expect(hit.fromTop, isTrue);
      expect(controller.showFromTop, isFalse); // 默认隐藏
      expect(controller.visibleHits, isEmpty);

      controller.setShowFromTop(true);
      expect(controller.visibleHits, hasLength(1));
    });

    test('新档位规则贯穿扫描：35%→一档、45%→二档、75%→三档', () async {
      final quotes = [
        _quote('600001', '甲股', price: 13.5), // pct 35 → 一档
        _quote('600002', '乙股', price: 14.5), // pct 45 → 二档（过 40 升档）
        _quote('600003', '丙股', price: 17.5), // pct 75 → 三档
      ];
      await setUpScan(const {}, quoteOverride: quotes);
      await controller.startScan();
      controller.setLimitUpFilter(false);
      controller.setSwingFilter(false);

      final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
      expect(bySymbol['600001']!.group, 1);
      expect(bySymbol['600001']!.threshold, 20.0);
      expect(bySymbol['600002']!.group, 2);
      expect(bySymbol['600002']!.threshold, 40.0);
      expect(bySymbol['600003']!.group, 3);
      expect(bySymbol['600003']!.threshold, 70.0);
      expect(controller.groupCounts, {1: 1, 2: 1, 3: 1});
    });
  });

  test('结果持久化（key v11），当日 restore 恢复；v10 旧结果作废', () async {
    await setUpScan(const {});
    await store.setState(
      'band_scan:last:v9',
      jsonEncode({
        'trade_date': _todayText,
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

    final raw = await store.getState('band_scan:last:v12');
    expect(raw, isNotNull);
    final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
    final rows = (persisted['hits'] as List).cast<Map>();
    expect(rows.any((item) => item['symbol'] == '600009'), isFalse);
    expect(persisted['scan_ms'], isNotNull);

    final restored = BandScanController(repository,
        nowFn: () => _today,
        fundamentals: fundamentals,
        lonCheck: lonCheck,
        autoComplete: false);
    await restored.restore();
    expect(restored.status, BandScanStatus.done);
    expect(restored.hits.any((item) => item.symbol == '600009'), isFalse);
    expect(restored.hits, hasLength(3));
    restored.dispose();
  });

  group('本地日K缺失的补齐', () {
    test('扫描记录缺失股票代码并随结果持久化/恢复', () async {
      await setUpScan(const {}, withoutBars: {'600002', '600003'});

      await controller.startScan();

      expect(controller.hits, hasLength(1)); // 只有 600001 参与判定
      expect(controller.skippedNoData, 2);
      expect(controller.skippedSymbols, ['600002', '600003']);

      final raw = await store.getState('band_scan:last:v12');
      final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
      expect(persisted['skipped_symbols'], ['600002', '600003']);

      final restored = BandScanController(repository,
          nowFn: () => _today,
          fundamentals: fundamentals,
          lonCheck: lonCheck,
          autoComplete: false);
      await restored.restore();
      expect(restored.skippedNoData, 2);
      expect(restored.skippedSymbols, ['600002', '600003']);
      restored.dispose();
    });

    test('补齐逐只补拉日K，完成后清空清单并给出重扫提示', () async {
      await setUpScan(
        const {},
        quoteOverride: [_quote('600001', '甲股'), _quote('600002', '乙股')],
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
      final raw = await store.getState('band_scan:last:v12');
      final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
      expect(persisted['skipped_symbols'], isEmpty);
      expect(persisted['skipped_no_data'], 0);

      // 补齐后重扫：600002 已有日K，能参与判定
      await controller.startScan();
      expect(
          controller.hits.map((hit) => hit.symbol).toSet(), {'600001', '600002'});
      expect(controller.skippedNoData, 0);
    });

    test('补完仍不足20根的（次新/长期停牌）不再计入待补，提示写明无法补齐', () async {
      await setUpScan(
        const {},
        quoteOverride: [
          _quote('600001', '甲股'),
          _quote('600002', '次新股'),
          _quote('600003', '停牌股'),
        ],
        withoutBars: {'600002', '600003'},
        backfillShortData: {'600003'}, // 补回来也只有 5 根
      );
      await controller.startScan();
      expect(controller.skippedSymbols, ['600002', '600003']);

      await controller.backfillMissing();

      // 600002 补齐成功；600003 数据源本身不足 → 不再留在待补清单
      expect(controller.skippedSymbols, isEmpty);
      expect(controller.skippedNoData, 0);
      expect(controller.unfixableCount, 1);
      expect(controller.backfillNote, contains('无法补齐'));
    });

    test('单只补齐失败留在清单里，可以再点一次', () async {
      await setUpScan(
        const {},
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
        const {},
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
      await setUpScan(const {});
      await controller.startScan();
      expect(controller.skippedSymbols, isEmpty);

      await controller.backfillMissing();
      expect(sync.refreshed, isEmpty);
      expect(controller.backfilling, isFalse);
      expect(controller.backfillNote, isNull);
    });
  });

  test('旧持久化数据缺标记字段 → 未知（null），不是 false', () {
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
    expect(hit.revenueOk, isNull);
    expect(hit.lonOk, isNull);
    expect(hit.marksKnown, isFalse);
    expect(hit.turnover, isNull);
    expect(hit.chg3, isNull);
  });
}
