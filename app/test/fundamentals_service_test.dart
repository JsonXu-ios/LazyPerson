/// 八档局基本面标记（分红/净利润）单测。
/// 纯判定函数的数值断言与 tests/test_scanner.py::TestFundamentals 对齐；
/// 差别：backend 用净利率反推营收（baostock 缺营收字段），
/// app 用东财直接拿营收，判定式为 营收×4×10 > 总市值。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/fundamentals_service.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/providers/eastmoney_fundamentals_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 按 URL 里的 reportName 返回预置响应（东财真实响应是 text/plain）
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('profitCondition（对齐 TestFundamentals.test_profit_condition）', () {
    // 茅台2026Q1：归母净利281.5亿；backend 由净利率0.522245反推营收≈539亿，
    // app 直接用营收。539亿×40 ≈ 2.16万亿 > 市值1.61万亿 → 通过
    const netProfit = 28153831489.89;
    const revenue = netProfit / 0.522245;

    test('茅台例通过；市值3万亿不通过', () {
      expect(profitCondition(netProfit, revenue, 16119.8), isTrue);
      expect(profitCondition(netProfit, revenue, 30000.0), isFalse);
    });

    test('归母净利为负 / 数据缺失 → 不通过', () {
      expect(profitCondition(-1000.0, 10000.0, 50.0), isFalse);
      expect(profitCondition(null, 10000.0, 50.0), isFalse);
      expect(profitCondition(1000.0, null, 50.0), isFalse);
      expect(profitCondition(1000.0, 0.0, 50.0), isFalse);
      expect(profitCondition(1000.0, 10000.0, null), isFalse);
      expect(profitCondition(1000.0, 10000.0, 0.0), isFalse);
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

    test('拉东财两个接口打标并写缓存（3 天内二次调用不再请求）', () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report(_bonusRows),
        'RPT_LICO_FN_CPD': _report([_q1Row]),
      });
      final service = _service(store, adapter);

      final marks = await service.marksFor('600519', 16119.8);
      expect(marks.dividendRecent, isTrue);
      expect(marks.profitOk, isTrue);
      expect(
          adapter.requestedUrls.where((u) => u.contains('RPT_SHAREBONUS_DET')),
          hasLength(1));
      // 一季报按 REPORTDATE 精确过滤
      expect(
          adapter.requestedUrls
              .where((u) => u.contains('RPT_LICO_FN_CPD'))
              .single,
          contains('2026-03-31'));

      final raw = await store.getState('fundamentals:v1:600519');
      expect(raw, isNotNull);
      final cached = (jsonDecode(raw!) as Map).cast<String, Object?>();
      expect(cached['checked_at'], '2026-08-03');
      expect(cached['dividend_recent'], isTrue);
      expect(cached['profit_ok'], isTrue);

      final requestsBefore = adapter.requestedUrls.length;
      final again = await service.marksFor('600519', 16119.8);
      expect(again.dividendRecent, isTrue);
      expect(adapter.requestedUrls.length, requestsBefore); // 缓存命中，零请求
    });

    test('缓存超过 3 天失效重新取数', () async {
      await store.setState(
        'fundamentals:v1:600519',
        jsonEncode({
          'checked_at': '2026-07-30', // 4 天前
          'dividend_recent': false,
          'profit_ok': false,
        }),
      );
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report(_bonusRows),
        'RPT_LICO_FN_CPD': _report([_q1Row]),
      });

      final marks = await _service(store, adapter).marksFor('600519', 16119.8);
      expect(marks.dividendRecent, isTrue); // 用的是新数据而非过期缓存
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
        'RPT_LICO_FN_CPD': _report([_q1Row]),
      });

      final marks = await _service(store, adapter).marksFor('600001', 16119.8);
      expect(marks.dividendRecent, isFalse);
      expect(marks.profitOk, isTrue);
    });

    test('一季报未披露 → profitOk 不通过', () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': _report(_bonusRows),
        'RPT_LICO_FN_CPD': _report([]),
      });

      final marks = await _service(store, adapter).marksFor('600519', 16119.8);
      expect(marks.profitOk, isFalse);
      expect(marks.dividendRecent, isTrue);
    });

    test('取数失败向上抛且不写缓存（下次重试）', () async {
      final adapter = _FakeAdapter({
        'RPT_SHAREBONUS_DET': 'not json at all',
        'RPT_LICO_FN_CPD': _report([_q1Row]),
      });
      final service = _service(store, adapter);

      await expectLater(
          service.marksFor('600519', 16119.8), throwsA(anything));
      expect(await store.getState('fundamentals:v1:600519'), isNull);
    });
  });
}
