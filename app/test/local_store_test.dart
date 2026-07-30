import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/market_repository.dart';
import 'package:lazyperson/data/sync_service.dart';
import 'package:lazyperson/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<LocalStore> _openStore() async {
  return LocalStore(await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) async {
        // 复用 LocalStore.open 的建表逻辑：直接调用一次真实 open 不可行（路径），
        // 这里通过临时 LocalStore 建表语句保持单一来源。
        await LocalStore.createSchema(db);
      },
    ),
  ));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;

  setUp(() async {
    store = await _openStore();
  });

  tearDown(() => store.close());

  test('symbols upsert 与本地搜索（代码/名称/拼音首字母）', () async {
    await store.upsertSymbols(const [
      SymbolItem(symbol: '600519', market: 'SH', name: '贵州茅台', pinyinAbbr: 'GZMT'),
      SymbolItem(symbol: '000001', market: 'SZ', name: '平安银行', pinyinAbbr: 'PAYH'),
      SymbolItem(symbol: '002138', market: 'SZ', name: '顺络电子', pinyinAbbr: 'SLDZ'),
    ]);
    expect(await store.symbolCount(), 3);

    expect((await store.searchSymbols('600')).single.symbol, '600519');
    expect((await store.searchSymbols('茅台')).single.symbol, '600519');
    expect((await store.searchSymbols('payh')).single.symbol, '000001');
    expect((await store.searchSymbols('SLD')).single.symbol, '002138');
    expect(await store.searchSymbols('不存在'), isEmpty);
  });

  test('daily_bars upsert / 读取 / 90 天裁剪', () async {
    await store.upsertDailyBars('600519', const [
      KlineBar(time: '2026-03-02', open: 1, high: 2, low: 0.5, close: 1.5),
      KlineBar(time: '2026-06-01', open: 1, high: 2, low: 0.5, close: 1.6),
      KlineBar(time: '2026-07-17', open: 1, high: 2, low: 0.5, close: 1.7),
    ]);
    // 同日 upsert 覆盖
    await store.upsertDailyBars('600519', const [
      KlineBar(time: '2026-07-17', open: 1, high: 2, low: 0.5, close: 1.8),
    ]);
    var bars = await store.getDailyBars('600519');
    expect(bars.length, 3);
    expect(bars.last.close, 1.8);
    expect(await store.latestDailyDate('600519'), '2026-07-17');

    final removed = await store.pruneDailyBars('2026-04-21');
    expect(removed, 1);
    bars = await store.getDailyBars('600519');
    expect(bars.first.time, '2026-06-01');
  });

  test('watchlist 增删与排序', () async {
    await store.upsertSymbols(const [
      SymbolItem(symbol: '600519', market: 'SH', name: '贵州茅台'),
    ]);
    await store.addWatchlist('600519', 'a_share');
    await store.addWatchlist('000001', 'a_share');
    var rows = await store.listWatchlist();
    expect(rows.length, 2);
    expect(rows.first.symbol, '600519');
    expect(rows.first.name, '贵州茅台');
    expect(rows.first.sortOrder, 1);
    expect(rows.last.sortOrder, 2);

    await store.removeWatchlist('600519');
    rows = await store.listWatchlist();
    expect(rows.single.symbol, '000001');
  });

  test('frames 缓存 TTL 与 stale 读取', () async {
    await store.writeFrame(
      cacheKey: 'k',
      dataType: 'quote',
      payloadJson: '[]',
      source: 'tencent',
      ttl: const Duration(milliseconds: 1),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(await store.readFrame('k'), isNull);
    final stale = await store.readFrame('k', allowStale: true);
    expect(stale, isNotNull);
    expect(stale!.stale, isTrue);
    expect(stale.source, 'tencent');
  });

  test('sync_state 断点记录', () async {
    await store.setSyncState('600519', '2026-07-17', 'done');
    await store.setSyncState('000001', '', 'error');
    final synced = await store.syncedDates();
    expect(synced, {'600519': '2026-07-17'});
  });

  test('行情里的名称落进 symbols，自选列表不再只剩代码', () async {
    // listWatchlist 的 name 是 join symbols 拿的；全市场同步没跑完时那张表是空的
    final sync = SyncService(store: store);
    final repo = MarketRepository(store: store, sync: sync);
    await store.addWatchlist('600360', 'a_share');
    expect((await store.listWatchlist()).single.name, '');

    await repo.rememberQuoteNames(const [
      Quote(symbol: '600360', market: 'SH', name: '华微电子', price: 9.04),
      Quote(symbol: '000001', market: 'SZ', name: '', price: 11.61), // 空名不写
    ]);

    expect((await store.listWatchlist()).single.name, '华微电子');
    expect(await store.getSymbol('000001'), isNull);
  });

  test('清掉历史种下的非 A 股自选（美股/黄金/加密）', () async {
    // 删种子代码不会删已落库的数据，残留一条 SPY 会让整批行情请求失败、
    // 退化成日 K 兜底（name/market 变空，界面标题退回代码）
    await store.upsertSymbols(const [
      SymbolItem(symbol: '600519', market: 'SH', name: '贵州茅台'),
      SymbolItem(symbol: 'SPY', market: 'US', name: '标普500 ETF'),
      SymbolItem(symbol: 'GC=F', market: 'FUT', name: 'COMEX 黄金期货'),
    ]);
    await store.addWatchlist('600519', 'a_share');
    await store.addWatchlist('SPY', 'us');
    await store.addWatchlist('BTC-USD', 'crypto');

    final removed = await store.purgeNonAShare();

    expect(removed, 2);
    expect((await store.listWatchlist()).map((item) => item.symbol), ['600519']);
    expect(await store.getSymbol('SPY'), isNull);
    expect((await store.getSymbol('600519'))?.name, '贵州茅台');
  });

  test('ensureSeeded 会补跑一次非 A 股清理', () async {
    final sync = SyncService(store: store);
    final repo = MarketRepository(store: store, sync: sync);
    // 模拟旧版本已经种过全球自选（种子标记也已置位）
    await store.addWatchlist('SPY', 'us');
    await store.setState('watchlist_seeded', '1');

    await repo.ensureSeeded();

    expect((await store.listWatchlist()).map((item) => item.symbol),
        isNot(contains('SPY')));
  });

  test('repository 种子数据只写一次', () async {
    final sync = SyncService(store: store);
    final repo = MarketRepository(store: store, sync: sync);
    await repo.ensureSeeded();
    await repo.ensureSeeded();
    final rows = await store.listWatchlist();
    expect(rows.length, MarketRepository.defaultWatchlist.length);
    // 只做 A 股，种子全部落在 a_share 分组
    expect(rows.map((row) => row.groupName).toSet(), {'a_share'});
  });
}
