/// 八档局基本面标记（分红/净利润/估市值）单测。
/// 纯判定函数的数值断言与 tests/test_scanner.py::TestFundamentals 对齐；
/// 差别：backend 用净利率反推营收（baostock 缺营收字段），
/// app 用东财直接拿营收，判定式为 营收×年化系数×10 > 总市值。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/fundamentals_service.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/providers/eastmoney_fundamentals_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 按 URL 里的子串返回预置响应（东财真实响应是 text/plain）。
/// 报告期回退用日期子串区分同一接口的不同 REPORTDATE 过滤。
class _FakeAdapter implements HttpClientAdapter {
  final Map<String, String> bodies;
  final List<String> requestedUrls = [];

  _FakeAdapter(this.bodies);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requestedUrls.add(url);
    for (final entry in bodies.entries) {
      if (url.contains(entry.key)) {
        return ResponseBody.fromString(entry.value, 200, headers: {
          Headers.contentTypeHeader: ['text/plain;charset=UTF-8'],
        });
      }
    }
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: ['text/plain;charset=UTF-8'],
    });
  }

  @override
  void close({bool force = false}) {}
}

String _report(List<Map<String, Object?>> rows) =>
    jsonEncode({'result': {'data': rows}, 'success': true});

/// 茅台 2026Q1 真实字段（curl 实测 RPT_LICO_FN_CPD 返回）
final _q1Row = {
  'SECURITY_CODE': '600519',
  'SECURITY_NAME_ABBR': '贵州茅台',
  'REPORTDATE': '2026-03-31 00:00:00',
  'DATATYPE': '2026年 一季报',
  'TOTAL_OPERATE_INCOME': 54702912385.23,
  'PARENT_NETPROFIT': 27242512886.45,
};

/// 半年报口径：同样营收数字，年化只 ×2（用于报告期系数差异断言）
final _h1Row = {
  'SECURITY_CODE': '600519',
  'SECURITY_NAME_ABBR': '贵州茅台',
  'REPORTDATE': '2026-06-30 00:00:00',
  'DATATYPE': '2026年 半年报',
  'TOTAL_OPERATE_INCOME': 54702912385.23,
  'PARENT_NETPROFIT': 27242512886.45,
};

/// 分红送配真实字段（curl 实测 RPT_SHAREBONUS_DET 返回）：
/// 一条已实施（有除权除息日）、一条预披露（现金分红为 null，不算数）
final _bonusRows = [
  {
    'SECURITY_CODE': '600519',
    'REPORT_DATE': '2026-06-30 00:00:00',
    'ASSIGN_PROGRESS': '预披露',
    'PRETAX_BONUS_RMB': null,
    'PLAN_NOTICE_DATE': '2026-04-17 00:00:00',
    'EX_DIVIDEND_DATE': null,
  },
  {
    'SECURITY_CODE': '600519',
    'REPORT_DATE': '2025-12-31 00:00:00',
    'ASSIGN_PROGRESS': '实施分配',
    'PRETAX_BONUS_RMB': 280.2423,
    'PLAN_NOTICE_DATE': '2026-04-17 00:00:00',
    'EX_DIVIDEND_DATE': '2026-06-26 00:00:00',
  },
];

Future<LocalStore> _openStore() async {
  return LocalStore(await databaseFactory.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: (db, version) => LocalStore.createSchema(db),
    ),
  ));
}

FundamentalsService _service(LocalStore store, _FakeAdapter adapter) {
  final dio = Dio(BaseOptions(headers: {'User-Agent': 'test'}));
  dio.httpClientAdapter = adapter;
  return FundamentalsService(
    store: store,
    provider: EastmoneyFundamentalsProvider(dio),
    nowFn: () => DateTime(2026, 8, 3),
  );
}

/// 只记账不打网络的假实现，用来观察 marksForMany 的并发行为
class _CountingFundamentals extends FundamentalsService {
  final Set<String> failing;
  final List<String> requested = [];
  final Map<String, double?> capsSeen = {};
  int inFlight = 0;
  int maxInFlight = 0;

  _CountingFundamentals(LocalStore store, {this.failing = const {}})
      : super(store: store);

  @override
  Future<FundamentalsMarks> marksFor(String symbol, double? marketCapYi) async {
    requested.add(symbol);
    capsSeen[symbol] = marketCapYi;
    inFlight += 1;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (failing.contains(symbol)) throw StateError('failed: $symbol');
      return const FundamentalsMarks(
          dividendRecent: true, profitOk: true, revenueOk: true);
    } finally {
      inFlight -= 1;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('annualizeFactor（对齐 TestFundamentals.test_annualize_factor）', () {
    test('一季报×4、半年报×2、三季报×4/3、年报×1', () {
      expect(annualizeFactor('2026-03-31'), 4.0);
      expect(annualizeFactor('2026-06-30'), 2.0);
      expect(annualizeFactor('2026-09-30'), closeTo(4 / 3, 1e-9));
      expect(annualizeFactor('2025-12-31'), 1.0);
    });

    test('缺失/脏数据/非报告期月份 → null', () {
      expect(annualizeFactor(null), isNull);
      expect(annualizeFactor('bad'), isNull);
      expect(annualizeFactor('2026-05-31'), isNull);
    });
  });

  group('revenueCondition（对齐 TestFundamentals.test_revenue_condition）', () {
    // 茅台2026Q1：营收547亿 ×4×10 ≈ 2.19万亿 > 市值1.61万亿 → 通过
    const revenue = 54702912385.23;

    test('茅台一季报通过；市值3万亿不通过', () {
      expect(revenueCondition(revenue, '2026-03-31', 16119.8), isTrue);
      expect(revenueCondition(revenue, '2026-03-31', 30000.0), isFalse);
    });

    test('同样营收若是半年报：×2×10≈1.09万亿 < 1.61万亿 → 不通过', () {
      expect(revenueCondition(revenue, '2026-06-30', 16119.8), isFalse);
    });

    test('年报不年化：547亿×10 < 1.61万亿 → 不通过', () {
      expect(revenueCondition(revenue, '2025-12-31', 16119.8), isFalse);
    });

    test('数据缺失/非正 → 不通过', () {
      expect(revenueCondition(null, '2026-03-31', 50.0), isFalse);
      expect(revenueCondition(0.0, '2026-03-31', 50.0), isFalse);
      expect(revenueCondition(1000.0, null, 50.0), isFalse);
      expect(revenueCondition(1000.0, '2026-03-31', null), isFalse);
      expect(revenueCondition(1000.0, '2026-03-31', 0.0), isFalse);
    });
  });

  group('profitCondition（对齐 TestFundamentals.test_profit_condition）', () {
    test('归母净利润≥0 通过（正/零），负/缺失不通过', () {
      expect(profitCondition(28153831489.89), isTrue);
      expect(profitCondition(0.0), isTrue);
      expect(profitCondition(-1000.0), isFalse);
      expect(profitCondition(null), isFalse);
    });
  });

  group('latestReportCandidates（最近已结束报告期回退序列）', () {
    test('8月 → 半年报/一季报/去年年报/去年三季报', () {
      expect(latestReportCandidates(DateTime(2026, 8, 3)),
          ['2026-06-30', '2026-03-31', '2025-12-31', '2025-09-30']);
    });

    test('报告期未结束不入候选（3月底一季度还没结束）', () {
      expect(latestReportCandidates(DateTime(2026, 3, 31)),
          ['2025-12-31', '2025-09-30', '2025-06-30', '2025-03-31']);
    });
  });

  group('dividendCondition（对齐 TestFundamentals.test_dividend_condition）', () {
    final today = DateTime(2026, 8, 3);

    test('近一年内有除权除息 → true', () {
      expect(dividendCondition(['2026-06-26'], today), isTrue);
      expect(dividendCondition(['2025-12-19'], today), isTrue);
    });

    test('已公告、除息日在未来（今年分红计划）→ true', () {
      expect(dividendCondition(['2026-09-10'], today), isTrue);
    });

    test('超过一年 → false', () {
      expect(dividendCondition(['2025-06-26'], today), isFalse);
    });

    test('无记录/脏数据 → false', () {
      expect(dividendCondition([], today), isFalse);
      expect(dividendCondition(['', 'bad-date'], today), isFalse);
    });
  });

  group('FundamentalsService 取数 + sqlite 缓存', () {
    late LocalStore store;

    setUp(() async {
      store = await _openStore();
    });

    tearDown(() => store.close());

    test('最新期（半年报）无数据回退一季报，打标并写缓存（3 天内二次调用不再请求）',
        () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report(_bonusRows),
        '2026-06-30': _report([]), // 半年报未披露 → 回退
        '2026-03-31': _report([_q1Row]),
      });
      final service = _service(store, adapter);

      final marks = await service.marksFor('600519', 16119.8);
      expect(marks.dividendRecent, isTrue);
      expect(marks.profitOk, isTrue); // 归母净利 272 亿 ≥ 0
      expect(marks.revenueOk, isTrue); // 547亿×4×10 ≈ 2.19万亿 > 1.61万亿
      expect(
          adapter.requestedUrls.where((u) => u.contains('RPT_SHAREBONUS_DET')),
          hasLength(1));
      // 报告期按 REPORTDATE 从最近往回试：先 2026-06-30（空）再 2026-03-31
      final licoUrls = adapter.requestedUrls
          .where((u) => u.contains('RPT_LICO_FN_CPD'))
          .toList();
      expect(licoUrls, hasLength(2));
      expect(licoUrls[0], contains('2026-06-30'));
      expect(licoUrls[1], contains('2026-03-31'));

      final raw = await store.getState('fundamentals:v2:600519');
      expect(raw, isNotNull);
      final cached = (jsonDecode(raw!) as Map).cast<String, Object?>();
      expect(cached['checked_at'], '2026-08-03');
      expect(cached['dividend_recent'], isTrue);
      expect(cached['profit_ok'], isTrue);
      expect(cached['revenue_ok'], isTrue);

      final requestsBefore = adapter.requestedUrls.length;
      final again = await service.marksFor('600519', 16119.8);
      expect(again.dividendRecent, isTrue);
      expect(again.revenueOk, isTrue);
      expect(adapter.requestedUrls.length, requestsBefore); // 缓存命中，零请求
    });

    test('最新期是半年报：年化×2 → 1.09万亿 < 1.61万亿 → revenueOk 不通过',
        () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report(_bonusRows),
        '2026-06-30': _report([_h1Row]),
      });

      final marks = await _service(store, adapter).marksFor('600519', 16119.8);
      expect(marks.profitOk, isTrue);
      expect(marks.revenueOk, isFalse);
      // 最新期有数据就不再回退
      expect(
          adapter.requestedUrls.where((u) => u.contains('RPT_LICO_FN_CPD')),
          hasLength(1));
    });

    test('市值过大（3万亿）→ revenueOk 不通过、profitOk 不受影响', () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report(_bonusRows),
        '2026-06-30': _report([]),
        '2026-03-31': _report([_q1Row]),
      });

      final marks = await _service(store, adapter).marksFor('600519', 30000.0);
      expect(marks.revenueOk, isFalse); // 547亿×4×10 ≈ 2.19万亿 < 3万亿
      expect(marks.profitOk, isTrue);
    });

    test('缓存超过 3 天失效重新取数', () async {
      await store.setState(
        'fundamentals:v2:600519',
        jsonEncode({
          'checked_at': '2026-07-30', // 4 天前
          'dividend_recent': false,
          'profit_ok': false,
          'revenue_ok': false,
        }),
      );
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report(_bonusRows),
        '2026-06-30': _report([]),
        '2026-03-31': _report([_q1Row]),
      });

      final marks = await _service(store, adapter).marksFor('600519', 16119.8);
      expect(marks.dividendRecent, isTrue); // 用的是新数据而非过期缓存
      expect(marks.revenueOk, isTrue);
      expect(adapter.requestedUrls, isNotEmpty);
    });

    test('已公告未除息（除息日为空）用预案公告日，现金分红>0 才算', () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report([
          {
            'SECURITY_CODE': '600001',
            'ASSIGN_PROGRESS': '董事会预案',
            'PRETAX_BONUS_RMB': 3.5,
            'PLAN_NOTICE_DATE': '2026-07-20 00:00:00',
            'EX_DIVIDEND_DATE': null,
          },
        ]),
        'RPT_LICO_FN_CPD': _report([]),
      });

      final marks = await _service(store, adapter).marksFor('600001', 100.0);
      expect(marks.dividendRecent, isTrue);
    });

    test('只有现金分红为 0/null 的记录 → 不算分红', () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report([
          {
            'SECURITY_CODE': '600001',
            'ASSIGN_PROGRESS': '预披露',
            'PRETAX_BONUS_RMB': null,
            'PLAN_NOTICE_DATE': '2026-07-20 00:00:00',
            'EX_DIVIDEND_DATE': null,
          },
          {
            'SECURITY_CODE': '600001',
            'ASSIGN_PROGRESS': '实施分配',
            'PRETAX_BONUS_RMB': 0,
            'PLAN_NOTICE_DATE': '2026-05-20 00:00:00',
            'EX_DIVIDEND_DATE': '2026-06-20 00:00:00',
          },
        ]),
        '2026-06-30': _report([_h1Row]),
      });

      final marks = await _service(store, adapter).marksFor('600001', 16119.8);
      expect(marks.dividendRecent, isFalse);
      expect(marks.profitOk, isTrue);
    });

    test('四期报告全部未披露 → profitOk/revenueOk 都不通过（回退4次后放弃）',
        () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report(_bonusRows),
        'RPT_LICO_FN_CPD': _report([]),
      });

      final marks = await _service(store, adapter).marksFor('600519', 16119.8);
      expect(marks.profitOk, isFalse);
      expect(marks.revenueOk, isFalse);
      expect(marks.dividendRecent, isTrue);
      // 2026-06-30 → 2026-03-31 → 2025-12-31 → 2025-09-30 共 4 期
      final licoUrls = adapter.requestedUrls
          .where((u) => u.contains('RPT_LICO_FN_CPD'))
          .toList();
      expect(licoUrls, hasLength(4));
      expect(licoUrls[2], contains('2025-12-31'));
      expect(licoUrls[3], contains('2025-09-30'));
    });

    test('取数失败向上抛且不写缓存（下次重试）', () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': 'not json at all',
        'RPT_LICO_FN_CPD': _report([_q1Row]),
      });
      final service = _service(store, adapter);

      await expectLater(
          service.marksFor('600519', 16119.8), throwsA(anything));
      expect(await store.getState('fundamentals:v2:600519'), isNull);
    });
  });

  group('marksForMany（批量并发）', () {
    late LocalStore store;

    setUp(() async {
      store = await _openStore();
    });

    tearDown(() => store.close());

    test('并发跑 marksFor：路数受限、失败的不进结果集、市值按 symbol 透传', () async {
      final service = _CountingFundamentals(store, failing: {'600003'});
      final symbols = [for (var i = 1; i <= 20; i++) '6000${i.toString().padLeft(2, '0')}'];
      final seen = <String, FundamentalsMarks?>{};

      final result = await service.marksForMany(
        symbols,
        marketCapOf: (symbol) => symbol == '600001' ? 100.0 : null,
        onEach: (symbol, marks) => seen[symbol] = marks,
      );

      expect(result.keys.toSet(), symbols.toSet()..remove('600003'));
      expect(seen['600003'], isNull); // 失败也会回调，marks 为 null
      expect(service.capsSeen['600001'], 100.0);
      expect(service.maxInFlight, greaterThan(1));
      expect(service.maxInFlight, lessThanOrEqualTo(fundamentalsFetchConcurrency));
    });

    test('shouldStop 变 true 后立刻停止取数', () async {
      final service = _CountingFundamentals(store);
      var stop = false;
      final symbols = [for (var i = 0; i < 100; i++) '60${i.toString().padLeft(4, '0')}'];

      final result = await service.marksForMany(
        symbols,
        shouldStop: () => stop,
        onEach: (_, _) {
          if (service.requested.length >= 10) stop = true;
        },
      );

      expect(result.length, lessThan(symbols.length));
      // 最多每路 worker 再多跑一只（停之前已经在飞的那只）
      expect(service.requested.length,
          lessThanOrEqualTo(10 + fundamentalsFetchConcurrency));
    });
  });

  /// 八档局纯本地扫描只读这份缓存：一次前缀查询，绝不联网
  group('cachedMarks / cachedMarksForMany（纯本地扫描用）', () {
    late LocalStore store;
    final today = DateTime(2026, 7, 24);

    setUp(() async {
      store = LocalStore(await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) => LocalStore.createSchema(db),
        ),
      ));
    });

    tearDown(() => store.close());

    Future<void> seed(String symbol, String checkedAt,
            {bool dividend = true}) =>
        store.setState(
          '$fundStatePrefix$symbol',
          jsonEncode({
            'checked_at': checkedAt,
            'dividend_recent': dividend,
            'profit_ok': true,
            'revenue_ok': false,
          }),
        );

    test('无缓存 → null（未知），不发请求', () async {
      final service = FundamentalsService(store: store, nowFn: () => today);
      expect(await service.cachedMarks('600001'), isNull);
      expect(await service.cachedMarksForMany(['600001']), isEmpty);
      expect(await service.cachedMarksForMany(const []), isEmpty);
    });

    test('3 天内的缓存命中，更早的按未知处理', () async {
      final service = FundamentalsService(store: store, nowFn: () => today);
      await seed('600001', '2026-07-24');
      await seed('600002', '2026-07-21'); // 3 天，仍有效
      await seed('600003', '2026-07-01'); // 过期

      expect((await service.cachedMarks('600001'))!.dividendRecent, isTrue);
      expect((await service.cachedMarks('600002'))!.profitOk, isTrue);
      expect(await service.cachedMarks('600003'), isNull);

      final many = await service
          .cachedMarksForMany(['600001', '600002', '600003', '600004']);
      expect(many.keys.toSet(), {'600001', '600002'});
      expect(many['600001']!.revenueOk, isFalse);
    });

    test('只返回请求的股票（前缀里其他股票不混进来）', () async {
      final service = FundamentalsService(store: store, nowFn: () => today);
      await seed('600001', '2026-07-24');
      await seed('600002', '2026-07-24');

      expect((await service.cachedMarksForMany(['600002'])).keys, ['600002']);
    });

    test('缓存损坏按未知处理', () async {
      final service = FundamentalsService(store: store, nowFn: () => today);
      await store.setState('${fundStatePrefix}600001', 'broken');
      expect(await service.cachedMarks('600001'), isNull);
      expect(await service.cachedMarksForMany(['600001']), isEmpty);
    });
  });
}
