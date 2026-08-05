/// SectorService 单测：热点榜/成分股 5 分钟缓存、概念板块全集按天缓存、
/// 个股行业与概念的过滤与热点标记。
/// 注入假 provider，不打网络。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/providers/eastmoney_sector_provider.dart';
import 'package:lazyperson/data/sector_service.dart';
import 'package:lazyperson/models/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

SectorBoard _board(String code, String name, String kind, double pct) =>
    SectorBoard(code: code, name: name, kind: kind, pctChg: pct);

/// 假东财板块源：记录调用次数，可指定某个接口抛错
class _FakeSectorProvider extends EastmoneySectorProvider {
  final List<SectorBoard> industryBoards;
  final List<SectorBoard> conceptBoards;
  final Map<String, List<SectorConstituent>> constituentsByCode;
  final Map<String, List<StockBoardRef>> boardsBySymbol;
  final Map<String, String> industryBySymbol;

  /// 置 true 让对应接口抛错，测降级
  bool failBoards = false;
  bool failStockBoards = false;
  bool failIndustry = false;

  int boardsCalls = 0;
  int constituentsCalls = 0;
  int stockBoardsCalls = 0;
  int industryCalls = 0;

  /// 每个个股接口的模拟 RTT，用来观察 sectorsOfMany 的并发度
  Duration stockDelay = Duration.zero;
  int inFlight = 0;
  int maxInFlight = 0;

  _FakeSectorProvider({
    this.industryBoards = const [],
    this.conceptBoards = const [],
    this.constituentsByCode = const {},
    this.boardsBySymbol = const {},
    this.industryBySymbol = const {},
  });

  @override
  Future<List<SectorBoard>> boards(String kind, {int limit = 60}) async {
    boardsCalls += 1;
    if (failBoards) throw StateError('boards down');
    final rows =
        kind == sectorKindIndustry ? industryBoards : conceptBoards;
    return rows.length > limit ? rows.sublist(0, limit) : rows;
  }

  @override
  Future<List<SectorConstituent>> constituents(String code,
      {int limit = 60}) async {
    constituentsCalls += 1;
    final rows = constituentsByCode[code] ?? const <SectorConstituent>[];
    return rows.length > limit ? rows.sublist(0, limit) : rows;
  }

  @override
  Future<List<StockBoardRef>> stockBoards(String symbol) async {
    stockBoardsCalls += 1;
    inFlight += 1;
    maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
    try {
      if (stockDelay > Duration.zero) await Future<void>.delayed(stockDelay);
      if (failStockBoards) throw StateError('slist down');
      return boardsBySymbol[symbol] ?? const <StockBoardRef>[];
    } finally {
      inFlight -= 1;
    }
  }

  @override
  Future<String> stockIndustry(String symbol) async {
    industryCalls += 1;
    if (failIndustry) throw StateError('stock/get down');
    return industryBySymbol[symbol] ?? '';
  }
}

final _today = DateTime(2026, 8, 5);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late LocalStore store;

  Future<LocalStore> openStore() async => LocalStore(
        await databaseFactory.openDatabase(
          inMemoryDatabasePath,
          options: OpenDatabaseOptions(
            version: 1,
            onCreate: (db, version) => LocalStore.createSchema(db),
          ),
        ),
      );

  SectorService service(_FakeSectorProvider provider,
          {DateTime Function()? nowFn}) =>
      SectorService(
        store: store,
        provider: provider,
        nowFn: nowFn ?? () => _today,
      );

  setUp(() async {
    store = await openStore();
  });

  tearDown(() => store.close());

  group('热点板块榜', () {
    test('行业/概念各取 Top N，涨幅降序（沿用服务端排序）', () async {
      final provider = _FakeSectorProvider(
        industryBoards: [
          _board('BK1625', '钨', sectorKindIndustry, 8.97),
          _board('BK1616', '白银', sectorKindIndustry, 8.4),
          _board('BK1325', '半导体材料', sectorKindIndustry, 8.1),
        ],
        conceptBoards: [
          _board('BK1152', '高带宽内存', sectorKindConcept, 7.63),
          _board('BK0890', 'MLCC', sectorKindConcept, 6.67),
        ],
      );
      final hot = await service(provider).hotBoards(limit: 2);
      expect(hot.industries.map((row) => row.name), ['钨', '白银']);
      expect(hot.concepts.map((row) => row.name), ['高带宽内存', 'MLCC']);
      expect(provider.boardsCalls, 2); // 行业 + 概念各一次
    });

    test('5 分钟内二次调用走缓存，refresh 强制重取', () async {
      // 两个榜都要给数据：空榜不写缓存（对齐 backend 的 empty 不落盘），
      // 只给一边会让另一边每次都重拉
      final provider = _FakeSectorProvider(
        industryBoards: [_board('BK1625', '钨', sectorKindIndustry, 8.97)],
        conceptBoards: [_board('BK1152', '高带宽内存', sectorKindConcept, 7.63)],
      );
      final sectors = service(provider);
      await sectors.hotBoards();
      expect(provider.boardsCalls, 2);

      await sectors.hotBoards();
      expect(provider.boardsCalls, 2); // 命中 frames 缓存，没再打接口

      await sectors.hotBoards(refresh: true);
      expect(provider.boardsCalls, 4);
    });

    test('取数失败回落到过期缓存（对齐 backend allow_stale）', () async {
      final provider = _FakeSectorProvider(
        conceptBoards: [_board('BK1152', '高带宽内存', sectorKindConcept, 7.63)],
      );
      final sectors = service(provider);
      await sectors.hotBoards();

      provider.failBoards = true;
      // refresh 绕过新鲜缓存 → 取数抛错 → 回落到已落盘的那份
      final hot = await sectors.hotBoards(refresh: true);
      expect(hot.concepts.map((row) => row.name), ['高带宽内存']);
    });

    test('没有任何缓存且取数失败 → 空榜单，不抛', () async {
      final provider = _FakeSectorProvider()..failBoards = true;
      final hot = await service(provider).hotBoards();
      expect(hot.isEmpty, isTrue);
    });
  });

  group('成分股', () {
    test('按涨幅降序返回并缓存 5 分钟', () async {
      final provider = _FakeSectorProvider(constituentsByCode: {
        'BK1625': const [
          SectorConstituent(symbol: '000657', name: '中钨高新', pctChg: 10.0),
          SectorConstituent(symbol: '002842', name: '翔鹭钨业', pctChg: 9.99),
        ],
      });
      final sectors = service(provider);
      final rows = await sectors.constituents('BK1625');
      expect(rows.map((row) => row.symbol), ['000657', '002842']);
      expect(provider.constituentsCalls, 1);

      await sectors.constituents('BK1625');
      expect(provider.constituentsCalls, 1); // 走缓存

      await sectors.constituents('BK1625', refresh: true);
      expect(provider.constituentsCalls, 2);
    });
  });

  group('概念板块全集（按天缓存）', () {
    test('首次拉全集并落 app_state，同日再取走缓存', () async {
      final provider = _FakeSectorProvider(conceptBoards: [
        _board('BK1152', '高带宽内存', sectorKindConcept, 7.63),
        _board('BK0596', '融资融券', sectorKindConcept, 1.88),
      ]);
      final sectors = service(provider);
      final map = await sectors.conceptBoardNames();
      expect(map, {'BK1152': '高带宽内存', 'BK0596': '融资融券'});
      expect(provider.boardsCalls, 1);

      await sectors.conceptBoardNames();
      expect(provider.boardsCalls, 1);

      final raw = await store.getState(sectorConceptBoardsKey);
      final payload = (jsonDecode(raw!) as Map).cast<String, Object?>();
      expect(payload['built_at'], '2026-08-05');
      expect((payload['boards'] as Map)['BK1152'], '高带宽内存');
    });

    test('隔日缓存作废，重新构建', () async {
      final provider = _FakeSectorProvider(conceptBoards: [
        _board('BK1152', '高带宽内存', sectorKindConcept, 7.63),
      ]);
      await service(provider).conceptBoardNames();
      expect(provider.boardsCalls, 1);

      // 换一天再取 → built_at 对不上，重建
      await service(provider, nowFn: () => DateTime(2026, 8, 6))
          .conceptBoardNames();
      expect(provider.boardsCalls, 2);
    });

    test('缓存损坏按无缓存处理', () async {
      await store.setState(sectorConceptBoardsKey, '{ not json');
      final provider = _FakeSectorProvider(conceptBoards: [
        _board('BK1152', '高带宽内存', sectorKindConcept, 7.63),
      ]);
      final map = await service(provider).conceptBoardNames();
      expect(map, {'BK1152': '高带宽内存'});
    });
  });

  group('个股行业与概念', () {
    /// 贵州茅台的实测形态：slist 返回行业(白酒Ⅱ)+地域(贵州板块)+概念，
    /// 只有在概念全集里的才算概念
    _FakeSectorProvider maotaiProvider() => _FakeSectorProvider(
          conceptBoards: [
            _board('BK0477', '酿酒概念', sectorKindConcept, 5.0),
            _board('BK0596', '融资融券', sectorKindConcept, 1.88),
            _board('BK0999', '茅指数', sectorKindConcept, 0.5),
          ],
          boardsBySymbol: {
            '600519': const [
              StockBoardRef(code: 'BK1277', name: '白酒Ⅱ'), // 行业，不在概念全集
              StockBoardRef(code: 'BK0173', name: '贵州板块'), // 地域，不在概念全集
              StockBoardRef(code: 'BK0477', name: '酿酒概念'),
              StockBoardRef(code: 'BK0596', name: '融资融券'),
              StockBoardRef(code: 'BK0999', name: '茅指数'),
            ],
          },
          industryBySymbol: {'600519': '白酒Ⅱ'},
        );

    test('行业走 f127，概念用概念全集过滤掉地域/行业板块', () async {
      final result = await service(maotaiProvider()).sectorsOf('600519');
      expect(result.industry, '白酒Ⅱ');
      expect(result.concepts, ['酿酒概念', '融资融券', '茅指数']);
      expect(result.isEmpty, isFalse);
    });

    test('概念命中今日热点榜前列 → hot=true，并列出命中的板块名', () async {
      final provider = maotaiProvider();
      final sectors = service(provider);
      // 概念榜前 2 名是 酿酒概念/融资融券
      final hotCodes = await sectors.hotConceptCodes(top: 2);
      expect(hotCodes, {'BK0477', 'BK0596'});

      final result = await sectors.sectorsOf('600519', hotCodes: hotCodes);
      expect(result.hot, isTrue);
      expect(result.hotConcepts, ['酿酒概念', '融资融券']); // 茅指数排第 3，不算热点
    });

    test('所属概念都不在热点榜 → hot=false', () async {
      final provider = maotaiProvider();
      final result =
          await service(provider).sectorsOf('600519', hotCodes: {'BK9999'});
      expect(result.hot, isFalse);
      expect(result.hotConcepts, isEmpty);
      expect(result.concepts, hasLength(3)); // 概念本身照常返回
    });

    test('行业/概念按天缓存：同日二次查询不再打接口', () async {
      final provider = maotaiProvider();
      final sectors = service(provider);
      await sectors.sectorsOf('600519', hotCodes: const {});
      expect(provider.stockBoardsCalls, 1);
      expect(provider.industryCalls, 1);

      await sectors.sectorsOf('600519', hotCodes: const {});
      expect(provider.stockBoardsCalls, 1);
      expect(provider.industryCalls, 1);

      // 热点标记不跟着按天缓存走：同一份缓存换热点集即时生效
      final hot =
          await sectors.sectorsOf('600519', hotCodes: {'BK0999'});
      expect(hot.hotConcepts, ['茅指数']);
      expect(provider.stockBoardsCalls, 1);
    });

    test('隔日重建个股板块缓存', () async {
      final provider = maotaiProvider();
      await service(provider).sectorsOf('600519', hotCodes: const {});
      expect(provider.stockBoardsCalls, 1);

      await service(provider, nowFn: () => DateTime(2026, 8, 6))
          .sectorsOf('600519', hotCodes: const {});
      expect(provider.stockBoardsCalls, 2);
    });

    test('slist 挂了仍给出行业（概念留空）', () async {
      final provider = maotaiProvider()..failStockBoards = true;
      final result =
          await service(provider).sectorsOf('600519', hotCodes: const {});
      expect(result.industry, '白酒Ⅱ');
      expect(result.concepts, isEmpty);
    });

    test('stock/get 挂了仍给出概念（行业留空）', () async {
      final provider = maotaiProvider()..failIndustry = true;
      final result =
          await service(provider).sectorsOf('600519', hotCodes: const {});
      expect(result.industry, '');
      expect(result.concepts, ['酿酒概念', '融资融券', '茅指数']);
    });

    test('概念全集拿不到时不做无过滤兜底（宁可留空，避免混进地域/指数板块）',
        () async {
      final provider = maotaiProvider()..failBoards = true;
      final result =
          await service(provider).sectorsOf('600519', hotCodes: const {});
      expect(result.industry, '白酒Ⅱ');
      expect(result.concepts, isEmpty);
    });

    test('查不到任何板块 → isEmpty，界面据此不渲染', () async {
      final provider = _FakeSectorProvider(
        conceptBoards: [_board('BK0477', '酿酒概念', sectorKindConcept, 5.0)],
      );
      final result =
          await service(provider).sectorsOf('000001', hotCodes: const {});
      expect(result.isEmpty, isTrue);
    });

    test('概念全集在同一个 service 实例里只解析一次（批量补标记不重复读盘）',
        () async {
      final provider = maotaiProvider();
      final sectors = service(provider);
      // 先落一次盘（boardsCalls=1）
      await sectors.conceptBoardNames();
      expect(provider.boardsCalls, 1);
      // 并发 10 次同时要：既不重复打接口，也不重复 decode
      final maps = await Future.wait(
          [for (var i = 0; i < 10; i++) sectors.conceptBoardNames()]);
      expect(provider.boardsCalls, 1);
      expect(maps.every((map) => map.length == 3), isTrue);
    });
  });

  group('sectorsOfMany（批量并发补标记）', () {
    _FakeSectorProvider batchProvider(List<String> symbols) =>
        _FakeSectorProvider(
          conceptBoards: [
            _board('BK0477', '酿酒概念', sectorKindConcept, 5.0),
            _board('BK0999', '茅指数', sectorKindConcept, 0.5),
          ],
          boardsBySymbol: {
            for (final symbol in symbols)
              symbol: const [
                StockBoardRef(code: 'BK0477', name: '酿酒概念'),
                StockBoardRef(code: 'BK0173', name: '贵州板块'), // 地域，过滤掉
                StockBoardRef(code: 'BK0999', name: '茅指数'),
              ],
          },
          industryBySymbol: {for (final symbol in symbols) symbol: '白酒Ⅱ'},
        );

    test('并发跑而不是逐只串行，耗时远低于串行下限', () async {
      final symbols = [for (var i = 0; i < 21; i++) '60${1000 + i}'];
      final provider = batchProvider(symbols)
        ..stockDelay = const Duration(milliseconds: 20);
      final sectors = service(provider);

      final startedAt = DateTime.now();
      final marks = await sectors.sectorsOfMany(symbols, hotCodes: {'BK0477'});
      final elapsed = DateTime.now().difference(startedAt);

      expect(marks, hasLength(21));
      expect(marks['601000']!.industry, '白酒Ⅱ');
      expect(marks['601000']!.concepts, ['酿酒概念', '茅指数']);
      expect(marks['601000']!.hot, isTrue);
      expect(provider.maxInFlight, greaterThan(1), reason: '必须并发');
      expect(provider.maxInFlight, lessThanOrEqualTo(sectorFetchConcurrency));
      // 串行下限 21×20ms=420ms；7 路并发 ≈ 3 轮 ≈ 60ms
      expect(elapsed.inMilliseconds, lessThan(420));
    });

    test('并发路数不超过 concurrency', () async {
      final symbols = [for (var i = 0; i < 12; i++) '60${2000 + i}'];
      final provider = batchProvider(symbols)
        ..stockDelay = const Duration(milliseconds: 10);
      await service(provider)
          .sectorsOfMany(symbols, hotCodes: const {}, concurrency: 3);
      expect(provider.maxInFlight, 3);
    });

    test('当日缓存命中的股票一个请求都不发', () async {
      final symbols = ['601000', '601001', '601002'];
      final provider = batchProvider(symbols);
      final sectors = service(provider);
      await sectors.sectorsOfMany(symbols, hotCodes: const {});
      expect(provider.stockBoardsCalls, 3);
      expect(provider.industryCalls, 3);

      // 第二轮全走 app_state 当日缓存
      final again = await sectors.sectorsOfMany(symbols, hotCodes: {'BK0999'});
      expect(provider.stockBoardsCalls, 3);
      expect(provider.industryCalls, 3);
      // 热点标记不跟着缓存走，换热点集即时生效
      expect(again['601000']!.hotConcepts, ['茅指数']);
    });

    test('单只失败不写结果、不影响其余（onEach 收到 null）', () async {
      final symbols = ['601000', '601001'];
      final provider = _FakeSectorProvider(
        conceptBoards: [_board('BK0477', '酿酒概念', sectorKindConcept, 5.0)],
        boardsBySymbol: {
          '601000': const [StockBoardRef(code: 'BK0477', name: '酿酒概念')],
        },
        industryBySymbol: const {'601000': '白酒Ⅱ'},
      );
      final failures = <String>[];
      final marks = await service(provider).sectorsOfMany(
        symbols,
        hotCodes: const {},
        onEach: (symbol, row) {
          if (row == null || row.isEmpty) failures.add(symbol);
        },
      );
      expect(marks['601000']!.industry, '白酒Ⅱ');
      expect(failures, ['601001']); // 查不到板块 → 调用方保持默认空/false
    });

    test('shouldStop 立刻收工（扫描被取消/重启）', () async {
      final symbols = [for (var i = 0; i < 30; i++) '60${3000 + i}'];
      final provider = batchProvider(symbols)
        ..stockDelay = const Duration(milliseconds: 5);
      var stop = false;
      final marks = await service(provider).sectorsOfMany(
        symbols,
        hotCodes: const {},
        concurrency: 2,
        onEach: (symbol, row) => stop = true, // 第一只回来就叫停
        shouldStop: () => stop,
      );
      expect(marks.length, lessThan(symbols.length));
      expect(provider.stockBoardsCalls, lessThan(symbols.length));
    });

    test('空列表不打接口', () async {
      final provider = batchProvider(const []);
      final marks =
          await service(provider).sectorsOfMany(const [], hotCodes: const {});
      expect(marks, isEmpty);
      expect(provider.stockBoardsCalls, 0);
      expect(provider.boardsCalls, 0);
    });
  });
}
