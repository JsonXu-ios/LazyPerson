/// 八档局扫描控制器的基本面标记流程测试：扫描完成后逐只补
/// dividendRecent/profitOk（注入假取数），取数失败不影响扫描结果，
/// 分红/净利润展示层过滤对齐网页版 MoneyGrabPanel。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/fundamentals_service.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/market_repository.dart';
import 'package:lazyperson/data/providers/eastmoney_provider.dart';
import 'package:lazyperson/data/sync_service.dart';
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

Quote _quote(String symbol, String name) => Quote(
      symbol: symbol,
      market: 'SH',
      name: name,
      price: 13.5, // 相对低点 10 涨 35% → 一档
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
  late BandScanController controller;

  Future<void> setUpScan(Map<String, FundamentalsMarks> marks) async {
    store = LocalStore(await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => LocalStore.createSchema(db),
      ),
    ));
    final quotes = [
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
    controller = BandScanController(
      repository,
      nowFn: () => _today,
      fundamentals: fundamentals,
    );
  }

  tearDown(() => store.close());

  test('扫描完成后逐只补标记；取数失败的股票保持默认 false 且不影响扫描结果', () async {
    await setUpScan({
      '600001': const FundamentalsMarks(dividendRecent: true, profitOk: true),
      '600003': const FundamentalsMarks(dividendRecent: false, profitOk: true),
      // 600002 缺失 → marksFor 抛异常，模拟取数失败
    });

    await controller.startScan();

    expect(controller.status, BandScanStatus.done);
    expect(controller.stage, '');
    expect(controller.hits, hasLength(3));
    // 只对命中的股票取数，市值来自扫描快照的 Quote.marketCap（亿元）
    expect(fundamentals.requested.toSet(), {'600001', '600002', '600003'});
    expect(fundamentals.capsSeen['600001'], 100.0);

    final bySymbol = {for (final hit in controller.hits) hit.symbol: hit};
    expect(bySymbol['600001']!.dividendRecent, isTrue);
    expect(bySymbol['600001']!.profitOk, isTrue);
    expect(bySymbol['600002']!.dividendRecent, isFalse); // 取数失败 → 默认 false
    expect(bySymbol['600002']!.profitOk, isFalse);
    expect(bySymbol['600003']!.dividendRecent, isFalse);
    expect(bySymbol['600003']!.profitOk, isTrue);
  });

  test('分红/净利润是展示层过滤（默认关），切换无需重扫', () async {
    await setUpScan({
      '600001': const FundamentalsMarks(dividendRecent: true, profitOk: true),
      '600003': const FundamentalsMarks(dividendRecent: false, profitOk: true),
    });
    await controller.startScan();
    controller.setLimitUpFilter(false); // 测试数据无涨停，先放开

    // 默认不勾选 → 不过滤
    expect(controller.dividendFilter, isFalse);
    expect(controller.profitFilter, isFalse);
    expect(controller.visibleHits, hasLength(3));

    controller.setDividendFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);

    controller.setDividendFilter(false);
    controller.setProfitFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol).toSet(),
        {'600001', '600003'});

    controller.setDividendFilter(true); // 两个都开取交集
    expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);
  });

  test('标记随结果持久化（key v4），当日 restore 恢复', () async {
    await setUpScan({
      '600001': const FundamentalsMarks(dividendRecent: true, profitOk: true),
    });
    await controller.startScan();

    final raw = await store.getState('band_scan:last:v4');
    expect(raw, isNotNull);
    final persisted = (jsonDecode(raw!) as Map).cast<String, Object?>();
    final rows = (persisted['hits'] as List).cast<Map>();
    final row = rows.firstWhere((item) => item['symbol'] == '600001');
    expect(row['dividend_recent'], isTrue);
    expect(row['profit_ok'], isTrue);

    final restored = BandScanController(
      repository,
      nowFn: () => _today,
      fundamentals: fundamentals,
    );
    await restored.restore();
    expect(restored.status, BandScanStatus.done);
    final hit = restored.hits.firstWhere((item) => item.symbol == '600001');
    expect(hit.dividendRecent, isTrue);
    expect(hit.profitOk, isTrue);
    restored.dispose();
  });
}
