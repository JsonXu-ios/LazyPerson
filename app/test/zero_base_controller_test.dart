/// 零帧起手扫描（破势第三个 tab）：独立于八档局的一次扫描 + 基本面补充。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/fundamentals_service.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/market_repository.dart';
import 'package:lazyperson/data/providers/eastmoney_provider.dart';
import 'package:lazyperson/data/sync_service.dart';
import 'package:lazyperson/models/models.dart';
import 'package:lazyperson/state/zero_base_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _today = DateTime(2026, 7, 24); // 周五

/// 全市场快照：扫描流程里唯一的网络请求
class _FakeEastmoney extends EastmoneyProvider {
  final List<Quote> quotes;
  int calls = 0;

  _FakeEastmoney(this.quotes);

  @override
  Future<List<Quote>> fullMarketSnapshot(
      {void Function(int loaded, int total)? onProgress}) async {
    calls += 1;
    return quotes;
  }
}

/// 基本面：marks 里有的返回，没有的抛错（模拟取数失败 → 保持未知）
class _FakeFundamentals extends FundamentalsService {
  final Map<String, FundamentalsMarks> marks;
  final List<String> requested = [];

  _FakeFundamentals(LocalStore store, this.marks)
      : super(store: store, nowFn: (() => _today));

  @override
  Future<FundamentalsMarks> marksFor(String symbol, double? marketCapYi) async {
    requested.add(symbol);
    final found = marks[symbol];
    if (found == null) throw StateError('fetch failed: $symbol');
    return found;
  }
}

Quote _quote(String symbol, String name,
        {double price = 10.1, double? turnover}) =>
    Quote(
      symbol: symbol,
      market: 'SH',
      name: name,
      tradeTime: '${_today.toIso8601String().substring(0, 10)} 15:00:00',
      price: price,
      open: price,
      high: price,
      low: price,
      preClose: price,
      marketCap: 100.0,
      turnover: turnover,
    );

/// 先高后低：平台 low×1.2，中途冲高到 low×(1+peakPct/100)，尾部探到 low 后横盘
List<KlineBar> _fallBars({double low = 10.0, double peakPct = 60}) {
  final bars = <KlineBar>[];
  for (var offset = 200; offset >= 0; offset--) {
    final day = _today.subtract(Duration(days: offset));
    if (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday) {
      continue;
    }
    bars.add(KlineBar(
      time: day.toIso8601String().substring(0, 10),
      open: low * 1.2,
      high: low * 1.22,
      low: low * 1.18,
      close: low * 1.2,
    ));
  }
  final lowIndex = bars.length - 5;
  final peakIndex = lowIndex - 15;
  final peak = low * (1 + peakPct / 100);
  bars[peakIndex] = KlineBar(
    time: bars[peakIndex].time,
    open: peak * 0.99,
    high: peak * 1.01,
    low: peak * 0.98,
    close: peak,
  );
  for (var i = lowIndex; i < bars.length; i++) {
    bars[i] = KlineBar(
      time: bars[i].time,
      open: low * 1.01,
      high: low * 1.02,
      low: i == lowIndex ? low : low * 1.002,
      close: low * 1.005,
    );
  }
  return bars;
}

/// 一路平推（从没到过高处）：不该命中
List<KlineBar> _flatBars({double low = 10.0}) =>
    _fallBars(low: low, peakPct: 10);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late _FakeEastmoney eastmoney;
  late _FakeFundamentals fundamentals;
  late MarketRepository repository;
  late ZeroBaseController controller;

  Future<void> boot(
    List<Quote> quotes, {
    Map<String, List<KlineBar>> bars = const {},
    Map<String, FundamentalsMarks> marks = const {},
    bool autoComplete = false,
  }) async {
    store = LocalStore(await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => LocalStore.createSchema(db),
      ),
    ));
    eastmoney = _FakeEastmoney(quotes);
    final sync = SyncService(
        store: store, eastmoney: eastmoney, now: (() => _today));
    repository = MarketRepository(store: store, sync: sync, now: () => _today);
    for (final entry in bars.entries) {
      await store.upsertDailyBars(entry.key, entry.value);
    }
    fundamentals = _FakeFundamentals(store, marks);
    controller = ZeroBaseController(
      repository,
      nowFn: () => _today,
      fundamentals: fundamentals,
      autoComplete: autoComplete,
    );
  }

  tearDown(() {
    controller.dispose();
    return store.close();
  });

  test('自己跑一次扫描：从 +50% 以上摔回低点的才命中，平推的不算', () async {
    await boot(
      [
        _quote('600001', '摔下来的', turnover: 5.0),
        _quote('600002', '平推的'),
        _quote('600003', '反弹走了', price: 12.0),
      ],
      bars: {
        '600001': _fallBars(peakPct: 60),
        '600002': _flatBars(), // 高点只有 +10%，够不上 50%
        '600003': _fallBars(peakPct: 60), // 形态一样但现价离低点 20%
      },
    );

    await controller.startScan();

    expect(controller.status, ZeroBaseStatus.done);
    expect(controller.hits.map((hit) => hit.symbol), ['600001']);
    final hit = controller.hits.single;
    expect(hit.group, 0);
    expect(hit.maxPct, closeTo(60, 1));
    expect(hit.turnover, 5.0); // 换手来自当日快照
    // 只发了一次网络请求（全市场快照），其余全走本地
    expect(eastmoney.calls, 1);
  });

  test('低于 50% 的高点不算（口径就是"至少从 50% 下来"）', () async {
    await boot(
      [_quote('600001', '只摔了30%')],
      bars: {'600001': _fallBars(peakPct: 30)},
    );

    await controller.startScan();

    expect(controller.hits, isEmpty);
  });

  test('当天行情算进去：快照写成当日 bar 后再判定', () async {
    await boot(
      [_quote('600001', '摔下来的')],
      bars: {'600001': _fallBars(peakPct: 60)},
    );

    await controller.startScan();

    // 快照那根当日 bar 已经落库（扫描窗口包含今天）
    final bars = await store.getDailyBars('600001');
    expect(bars.last.time, _today.toIso8601String().substring(0, 10));
    expect(controller.hits, hasLength(1));
  });

  test('基本面补充：分红/净利润/估市值三态，失败的保持未知可再点', () async {
    await boot(
      [_quote('600001', '甲'), _quote('600002', '乙')],
      bars: {
        '600001': _fallBars(peakPct: 60),
        '600002': _fallBars(peakPct: 80),
      },
      marks: {
        '600001': const FundamentalsMarks(
            dividendRecent: true, profitOk: true, revenueOk: true),
        // 600002 缺失 → 取数失败，保持未知
      },
    );

    await controller.startScan();
    expect(controller.unknownMarkCount, 2);

    await controller.enrichMarks();

    expect(controller.unknownMarkCount, 1);
    expect(controller.enrichNote, contains('仍未知'));
    final marked = controller.hits.firstWhere((hit) => hit.symbol == '600001');
    expect(marked.dividendRecent, isTrue);
    expect(marked.profitOk, isTrue);
    expect(marked.revenueOk, isTrue);
  });

  test('展示层筛选：分红/净利润/估市值/换手，未知的一律不显示', () async {
    await boot(
      [_quote('600001', '甲', turnover: 5.0), _quote('600002', '乙', turnover: 1.0)],
      bars: {
        '600001': _fallBars(peakPct: 60),
        '600002': _fallBars(peakPct: 80),
      },
      marks: {
        '600001': const FundamentalsMarks(
            dividendRecent: true, profitOk: true, revenueOk: false),
        '600002': const FundamentalsMarks(
            dividendRecent: false, profitOk: true, revenueOk: true),
      },
    );
    await controller.startScan();
    await controller.enrichMarks();

    expect(controller.visibleHits, hasLength(2));

    controller.setDividendFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);
    controller.setDividendFilter(false);

    controller.setRevenueFilter(true);
    expect(controller.visibleHits.map((hit) => hit.symbol), ['600002']);
    controller.setRevenueFilter(false);

    controller.setTurnoverFilter(true); // >3%
    expect(controller.visibleHits.map((hit) => hit.symbol), ['600001']);
  });

  test('结果落盘，当天重进直接恢复；分组按曾站上的最高主线', () async {
    await boot(
      [_quote('600001', '甲'), _quote('600002', '乙')],
      bars: {
        '600001': _fallBars(peakPct: 60), // 曾过 50 → stage 2
        '600002': _fallBars(peakPct: 120), // 曾过 110 → stage 4
      },
    );
    await controller.startScan();

    expect(controller.byPeak[2]!.single.symbol, '600001');
    expect(controller.byPeak[4]!.single.symbol, '600002');
    // 摔得最狠的排前面
    expect(controller.hits.first.symbol, '600002');

    final raw = await store.getState('zero_base:last:v1');
    expect((jsonDecode(raw!) as Map)['hits'], hasLength(2));

    final restored = ZeroBaseController(
      repository,
      nowFn: () => _today,
      fundamentals: fundamentals,
      autoComplete: false,
    );
    await restored.restore();
    expect(restored.status, ZeroBaseStatus.done);
    expect(restored.hits, hasLength(2));
    restored.dispose();
  });
}
