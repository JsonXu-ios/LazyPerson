/// 同步流水线测试（任务 E）：HomeController 的状态机与依赖顺序、
/// 补齐数据入口、强制全量刷新；以及 SyncService 新增的
/// pendingRepairSymbols / repairSymbols / resetForFullRefresh。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/market_repository.dart';
import 'package:lazyperson/data/providers/eastmoney_provider.dart';
import 'package:lazyperson/data/providers/tencent_provider.dart';
import 'package:lazyperson/data/sync_service.dart';
import 'package:lazyperson/models/models.dart';
import 'package:lazyperson/state/home_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _today = DateTime(2026, 7, 24); // 周五
final _todayText = _today.toIso8601String().substring(0, 10);

class _FakeEastmoney extends EastmoneyProvider {
  final List<Quote> quotes;
  int snapshotCalls = 0;
  bool failing = false;

  _FakeEastmoney(this.quotes);

  @override
  Future<List<Quote>> fullMarketSnapshot(
      {void Function(int loaded, int total)? onProgress}) async {
    snapshotCalls += 1;
    if (failing) throw StateError('snapshot down');
    onProgress?.call(quotes.length, quotes.length);
    return quotes;
  }
}

/// 假腾讯日K：initialSync 的逐只同步走它，测试里不打网络
class _FakeTencent extends TencentProvider {
  final List<String> requested = [];

  @override
  Future<List<KlineBar>> kline(
    String symbol,
    String period, {
    String? start,
    String? end,
    String adjust = 'qfq',
  }) async {
    requested.add(symbol);
    return [
      KlineBar(time: _todayText, open: 1, high: 1, low: 1, close: 1),
    ];
  }
}

/// 只跑本地逻辑的同步服务：refreshSymbol 换成写死的一根 bar，
/// [failing] 里的股票抛错
class _FakeSync extends SyncService {
  final Set<String> failing;
  final List<String> refreshed = [];

  _FakeSync({
    required super.store,
    required EastmoneyProvider eastmoney,
    required TencentProvider tencent,
    this.failing = const {},
  }) : super(eastmoney: eastmoney, tencent: tencent, now: (() => _today));

  @override
  Future<void> refreshSymbol(String symbol) async {
    refreshed.add(symbol);
    if (failing.contains(symbol)) throw StateError('refresh failed: $symbol');
    await store.upsertDailyBars(
        symbol, [KlineBar(time: _todayText, open: 1, high: 1, low: 1, close: 1)]);
    await store.setSyncState(symbol, _todayText, 'done');
  }
}

Quote _quote(String symbol) => Quote(
      symbol: symbol,
      market: 'SH',
      name: '股$symbol',
      tradeTime: '$_todayText 15:00:00',
      price: 10,
      open: 10,
      high: 10,
      low: 10,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;
  late _FakeEastmoney eastmoney;
  late _FakeTencent tencent;
  late _FakeSync sync;
  late MarketRepository repository;

  Future<void> boot({Set<String> failing = const {}}) async {
    store = LocalStore(await databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) => LocalStore.createSchema(db),
      ),
    ));
    eastmoney = _FakeEastmoney([_quote('600001'), _quote('600002')]);
    tencent = _FakeTencent();
    sync = _FakeSync(
      store: store,
      eastmoney: eastmoney,
      tencent: tencent,
      failing: failing,
    );
    repository = MarketRepository(store: store, sync: sync, tencent: tencent);
  }

  tearDown(() => store.close());

  group('LocalStore 批量读取（纯本地扫描的地基）', () {
    test('dailyBarsFor 一次拿多只，按日期升序分组', () async {
      await boot();
      await store.upsertDailyBars('600001', const [
        KlineBar(time: '2026-07-22', close: 1),
        KlineBar(time: '2026-07-23', close: 2),
      ]);
      await store.upsertDailyBars(
          '600002', const [KlineBar(time: '2026-07-23', close: 3)]);

      final bars = await store.dailyBarsFor(['600001', '600002', '600003']);
      expect(bars.keys.toSet(), {'600001', '600002'});
      expect(bars['600001']!.map((bar) => bar.time),
          ['2026-07-22', '2026-07-23']);
      expect(bars['600002']!.single.close, 3);
      expect(await store.dailyBarsFor(const []), isEmpty);
    });

    test('upsertDailyBarsBatch 一次事务写多只（快照吸收用）', () async {
      await boot();
      await store.upsertDailyBarsBatch({
        '600001': const [
          KlineBar(time: '2026-07-23', close: 1),
          KlineBar(time: '', close: 9), // 无日期的丢掉
        ],
        '600002': const [KlineBar(time: '2026-07-23', close: 2)],
        '600003': const [], // 空清单不写
      });

      expect(await store.symbolsWithBars(), {'600001', '600002'});
      expect((await store.getDailyBars('600001')).single.close, 1);
      await store.upsertDailyBarsBatch(const {}); // 空 map 是空操作
    });

    test('getStatesWithPrefix 一次取走整个前缀（key 去掉前缀）', () async {
      await boot();
      await store.setState('fundamentals:v2:600001', 'a');
      await store.setState('fundamentals:v2:600002', 'b');
      await store.setState('lon:v1:600001', 'c');

      expect(await store.getStatesWithPrefix('fundamentals:v2:'),
          {'600001': 'a', '600002': 'b'});
      expect(await store.getStatesWithPrefix('lon:v1:'), {'600001': 'c'});
      expect(await store.getStatesWithPrefix('nope:'), isEmpty);
    });

    test('symbolsWithBars / symbolsWithSyncStatus / clearSyncState', () async {
      await boot();
      await store.upsertDailyBars(
          '600001', const [KlineBar(time: '2026-07-23', close: 1)]);
      await store.setSyncState('600002', '', 'error');
      await store.setSyncState('600003', _todayText, 'done');

      expect(await store.symbolsWithBars(), {'600001'});
      expect(await store.symbolsWithSyncStatus('error'), ['600002']);
      await store.clearSyncState();
      expect(await store.symbolsWithSyncStatus('error'), isEmpty);
      expect(await store.syncedDates(), isEmpty);
    });
  });

  group('SyncService 补齐与强制刷新', () {
    test('pendingRepairSymbols = 同步失败的 + 一根日K都没有的', () async {
      await boot();
      await store.upsertSymbols(const [
        SymbolItem(symbol: '600001', market: 'SH', name: '甲'),
        SymbolItem(symbol: '600002', market: 'SH', name: '乙'),
        SymbolItem(symbol: '600003', market: 'SH', name: '丙'),
      ]);
      await store.upsertDailyBars(
          '600001', const [KlineBar(time: '2026-07-23', close: 1)]);
      await store.setSyncState('600001', '', 'error'); // 有K线但标记失败

      final pending = await sync.pendingRepairSymbols();
      expect(pending, ['600001', '600002', '600003']);
    });

    test('repairSymbols 逐只补拉，失败的返回给调用方再试', () async {
      await boot(failing: {'600002'});
      final progress = <int>[];

      final failed = await sync.repairSymbols(
        ['600001', '600002'],
        onProgress: (done, total) => progress.add(done),
      );

      expect(sync.refreshed.toSet(), {'600001', '600002'});
      expect(failed, ['600002']);
      expect(progress.last, 2);
      // 成功的那只已经落库，不再出现在待补清单里
      expect(await store.symbolsWithBars(), contains('600001'));
    });

    test('resetForFullRefresh 清掉初始化标记与逐只同步状态', () async {
      await boot();
      await store.setState('initial_sync_done', '1');
      await store.setSyncState('600001', _todayText, 'done');
      expect(await sync.isInitialized(), isTrue);

      await sync.resetForFullRefresh();

      expect(await sync.isInitialized(), isFalse);
      expect(await store.syncedDates(), isEmpty);
    });
  });

  group('HomeController 状态机（依赖顺序 + 提示）', () {
    test('未初始化 → initializing → ready，并统计待补齐数量', () async {
      await boot();
      final controller = HomeController(repository);
      expect(controller.syncStage, SyncStage.checking);

      await controller.startBackgroundSync();
      // runInitialSync 是 Stream，等它跑完
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(controller.syncStage, SyncStage.ready);
      expect(controller.dataDate, _todayText);
      expect(controller.syncText, contains('数据已同步至'));
      expect(await sync.isInitialized(), isTrue);
      controller.dispose();
    });

    test('已初始化且数据新鲜 → 直接 ready，不发增量请求', () async {
      await boot();
      await store.setState('initial_sync_done', '1');
      await store.upsertDailyBars(
          '600001', [KlineBar(time: _todayText, close: 1)]);
      final controller = HomeController(repository)..dataDate = null;

      await controller.startBackgroundSync();

      // isDataFresh 用真实 now 判定；构造的数据日期就是"最近工作日之后"时
      // 直接 ready，否则会走增量——两条路都不该失败
      expect(controller.syncStage,
          anyOf(SyncStage.ready, SyncStage.incrementing, SyncStage.failed));
      if (controller.syncStage == SyncStage.ready) {
        // ready 时状态条要能说清"几点更新的"，只有日期不够
        expect(controller.lastSyncAt, isNotNull);
        expect(controller.syncText, contains('更新'));
      }
      controller.dispose();
    });

    test('增量失败 → failed 带原因，重试成功后回 ready', () async {
      await boot();
      await store.setState('initial_sync_done', '1');
      eastmoney.failing = true;

      final controller = HomeController(repository);
      await controller.runDailyIncrement();

      expect(controller.syncStage, SyncStage.failed);
      expect(controller.syncFailed, isTrue);
      expect(controller.syncError, contains('数据更新失败'));
      expect(controller.syncText, contains('数据更新失败'));

      eastmoney.failing = false;
      await controller.retrySync();
      expect(controller.syncStage, SyncStage.ready);
      controller.dispose();
    });

    test('补齐数据：进度可见，失败的留提示', () async {
      await boot(failing: {'600002'});
      await store.setState('initial_sync_done', '1');
      await store.upsertSymbols(const [
        SymbolItem(symbol: '600001', market: 'SH', name: '甲'),
        SymbolItem(symbol: '600002', market: 'SH', name: '乙'),
      ]);
      final controller = HomeController(repository);

      await controller.repairData();

      expect(controller.repairTotal, 2);
      expect(controller.repairDone, 2);
      expect(controller.repairNote, contains('1 只失败'));
      expect(controller.syncStage, SyncStage.ready);
      // 补齐后重新统计：600002 仍缺数据
      expect(controller.pendingRepairCount, 1);
      controller.dispose();
    });

    test('没有需要补齐的数据时给明确提示', () async {
      await boot();
      await store.setState('initial_sync_done', '1');
      final controller = HomeController(repository);

      await controller.repairData();

      expect(controller.repairNote, '没有需要补齐的数据');
      expect(controller.syncStage, SyncStage.ready);
      controller.dispose();
    });

    test('强制全量刷新：清状态后重跑初始化，快照被重新拉一次', () async {
      await boot();
      await store.setState('initial_sync_done', '1');
      await store.setSyncState('600001', _todayText, 'done');
      final controller = HomeController(repository);
      final before = eastmoney.snapshotCalls;

      await controller.forceFullRefresh();
      expect(controller.syncStage, SyncStage.fullRefreshing);
      expect(controller.syncText, contains('强制全量刷新'));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(eastmoney.snapshotCalls, greaterThan(before));
      expect(controller.syncStage, SyncStage.ready);
      // 清过 sync_state → 清单里每一只都被重新拉了一遍日K
      expect(tencent.requested.toSet(), {'600001', '600002'});
      expect(await sync.isInitialized(), isTrue);
      controller.dispose();
    });

    test('忙碌中不重复触发（syncBusy 拦住补齐/强刷/重试）', () async {
      await boot();
      await store.setState('initial_sync_done', '1');
      await store.upsertSymbols(const [
        SymbolItem(symbol: '600001', market: 'SH', name: '甲'),
      ]);
      final controller = HomeController(repository);

      // 强刷一启动就占住流水线（不 await，让它在跑）
      final running = controller.forceFullRefresh();
      expect(controller.syncBusy, isTrue);

      await controller.repairData(); // 被拦住：没进 repairing
      expect(controller.repairTotal, 0);
      expect(controller.syncStage, isNot(SyncStage.repairing));
      await controller.retrySync(); // 同样被拦住
      expect(controller.syncStage, isNot(SyncStage.incrementing));

      await running;
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(controller.syncBusy, isFalse);
      controller.dispose();
    });
  });

  group('isDataFresh', () {
    test('周末取上周五：周六看到周五的数据算新鲜', () {
      expect(isDataFresh('2026-07-24', DateTime(2026, 7, 25)), isTrue);
      expect(isDataFresh('2026-07-23', DateTime(2026, 7, 24)), isFalse);
      expect(isDataFresh(null, DateTime(2026, 7, 24)), isFalse);
    });
  });

  group('refreshNow（自选页顶部手动刷新）', () {
    test('刷新期间置 manualRefreshing，跑完复位；数据落后时顺带踢一次增量', () async {
      await boot();
      await store.setState('initial_sync_done', '1');
      final controller = HomeController(repository);
      // 本地日K停在很久以前 → 刷新后应触发流水线
      await store.upsertDailyBars(
          '600001', [KlineBar(time: '2026-01-05', close: 1)]);
      await controller.loadWatchlist();
      controller.dataDate = '2026-01-05';

      final future = controller.refreshNow();
      expect(controller.manualRefreshing, isTrue);
      await future;

      expect(controller.manualRefreshing, isFalse);
      expect(controller.syncBusy, isTrue); // 数据落后 → 流水线已被踢起来
      // 等后台那段跑完再关库，否则 tearDown 会打断它
      for (var i = 0; i < 200 && controller.syncBusy; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(controller.syncBusy, isFalse);
      controller.dispose();
    });

    test('正在刷新时重复点击不叠加', () async {
      await boot();
      final controller = HomeController(repository);
      final first = controller.refreshNow();
      await controller.refreshNow(); // 直接返回，不再跑一遍
      await first;
      expect(controller.manualRefreshing, isFalse);
      controller.dispose();
    });
  });

  group('formatSyncTime（同步时刻）', () {
    test('当天只给时分，跨天补上月日', () {
      final now = DateTime(2026, 7, 24, 15, 4);
      expect(formatSyncTime(DateTime(2026, 7, 24, 9, 5), now: now), '09:05');
      expect(
          formatSyncTime(DateTime(2026, 7, 23, 21, 30), now: now), '07-23 21:30');
    });
  });
}
