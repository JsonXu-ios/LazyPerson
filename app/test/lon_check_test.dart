/// 八档局 LON 多头判定单测，用例逐条对齐
/// tests/test_scanner.py::TestLonTrend::test_lon_trend_ok。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/local_store.dart';
import 'package:lazyperson/data/lon_check_service.dart';
import 'package:lazyperson/logic/lon_check.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 只记账不打网络的假实现，用来观察 lonOkForMany 的并发行为
class _CountingLonCheck extends LonCheckService {
  final Set<String> failing;
  final List<String> requested = [];
  int inFlight = 0;
  int maxInFlight = 0;

  _CountingLonCheck(LocalStore store, {this.failing = const {}})
      : super(store: store);

  @override
  Future<bool> lonOkFor(String symbol) async {
    requested.add(symbol);
    inFlight += 1;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 1));
      if (failing.contains(symbol)) throw StateError('lon failed: $symbol');
      return true;
    } finally {
      inFlight -= 1;
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('lonTrendOk（对齐 TestLonTrend.test_lon_trend_ok）', () {
    test('lon、lonma 都向上且 lon 在 lonma 上方 → true', () {
      expect(lonTrendOk([100.0, 120.0], [90.0, 95.0]), isTrue);
    });

    test('lon 与 lonma 相等（贴线）也算未被压住 → true', () {
      expect(lonTrendOk([100.0, 120.0], [90.0, 120.0]), isTrue);
    });

    test('lonma 压在 lon 上面 → false', () {
      expect(lonTrendOk([100.0, 120.0], [130.0, 140.0]), isFalse);
    });

    test('lon 走平/向下 → false', () {
      expect(lonTrendOk([120.0, 120.0], [90.0, 95.0]), isFalse);
      expect(lonTrendOk([120.0, 110.0], [90.0, 95.0]), isFalse);
    });

    test('lonma 向下 → false', () {
      expect(lonTrendOk([100.0, 120.0], [96.0, 95.0]), isFalse);
    });

    test('数据不足/含 null → 按无效处理', () {
      expect(lonTrendOk([120.0], [95.0]), isFalse);
      expect(lonTrendOk([null, 120.0], [null, 95.0]), isFalse);
    });

    test('null 混入时取最后两对有效值：(100,90)→(120,95) 向上且未被压 → true', () {
      expect(lonTrendOk([100.0, null, 120.0], [90.0, null, 95.0]), isTrue);
    });
  });

  group('lonOkForMany（批量并发）', () {
    late LocalStore store;

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

    test('并发跑 lonOkFor：路数受限（每只三周期，比其他阶段保守），失败记 false', () async {
      final service = _CountingLonCheck(store, failing: {'600003'});
      final symbols = [
        for (var i = 1; i <= 20; i++) '6000${i.toString().padLeft(2, '0')}'
      ];

      final result = await service.lonOkForMany(symbols);

      expect(result.keys.toSet(), symbols.toSet());
      expect(result['600003'], isFalse); // 取数失败 → false，不影响其他
      expect(result['600001'], isTrue);
      expect(service.maxInFlight, greaterThan(1));
      expect(service.maxInFlight, lessThanOrEqualTo(lonFetchConcurrency));
      expect(lonFetchConcurrency, 6);
    });

    test('shouldStop 变 true 后立刻停止取数', () async {
      final service = _CountingLonCheck(store);
      var stop = false;
      final symbols = [
        for (var i = 0; i < 100; i++) '60${i.toString().padLeft(4, '0')}'
      ];

      final result = await service.lonOkForMany(
        symbols,
        shouldStop: () => stop,
        onEach: (_, _) {
          if (service.requested.length >= 10) stop = true;
        },
      );

      expect(result.length, lessThan(symbols.length));
      expect(service.requested.length,
          lessThanOrEqualTo(10 + lonFetchConcurrency));
    });
  });
}
