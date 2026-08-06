/// 八档局 LON 多头判定单测，用例逐条对齐
/// tests/test_scanner.py::TestLonTrend::test_lon_trend_ok。
library;

import 'dart:convert';

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

    test('并发跑 lonOkFor：路数受限（每只三周期，比其他阶段保守），失败的不进结果集', () async {
      final service = _CountingLonCheck(store, failing: {'600003'});
      final symbols = [
        for (var i = 1; i <= 20; i++) '6000${i.toString().padLeft(2, '0')}'
      ];
      final seen = <String, bool?>{};

      final result = await service.lonOkForMany(symbols,
          onEach: (symbol, ok) => seen[symbol] = ok);

      // 取数失败 = 未知：不写结果集，onEach 收到 null（调用方保持三态）
      expect(result.keys.toSet(), symbols.toSet()..remove('600003'));
      expect(result.containsKey('600003'), isFalse);
      expect(seen['600003'], isNull);
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

  /// 八档局纯本地扫描只读这份结论缓存，一次前缀查询拿完，绝不联网
  group('LON 结论缓存（纯本地扫描用）', () {
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

    Future<void> seed(String symbol, bool ok, String checkedAt) =>
        store.setState('$lonResultPrefix$symbol',
            jsonEncode({'checked_at': checkedAt, 'lon_ok': ok}));

    test('无缓存 → null（未知），不是 false', () async {
      final service = LonCheckService(store: store, nowFn: () => today);
      expect(await service.cachedOk('600001'), isNull);
      expect(await service.cachedOkForMany(['600001']), isEmpty);
    });

    test('当日缓存直接命中，过期的按未知处理', () async {
      final service = LonCheckService(store: store, nowFn: () => today);
      await seed('600001', true, '2026-07-24');
      await seed('600002', false, '2026-07-23'); // 1 天内仍有效
      await seed('600003', true, '2026-07-01'); // 过期

      expect(await service.cachedOk('600001'), isTrue);
      expect(await service.cachedOk('600002'), isFalse);
      expect(await service.cachedOk('600003'), isNull);

      final many =
          await service.cachedOkForMany(['600001', '600002', '600003', '600004']);
      expect(many, {'600001': true, '600002': false});
    });

    test('缓存损坏按未知处理', () async {
      final service = LonCheckService(store: store, nowFn: () => today);
      await store.setState('${lonResultPrefix}600001', '{not json');
      expect(await service.cachedOk('600001'), isNull);
      expect(await service.cachedOkForMany(['600001']), isEmpty);
    });
  });
}
