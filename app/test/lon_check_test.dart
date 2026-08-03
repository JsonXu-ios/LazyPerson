/// 八档局 LON 多头判定单测，用例逐条对齐
/// tests/test_scanner.py::TestLonTrend::test_lon_trend_ok。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/logic/lon_check.dart';

void main() {
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
}
