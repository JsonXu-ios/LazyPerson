import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/logic/indicators.dart';

import 'fixtures_util.dart';

void main() {
  group('indicators 与后端 indicators.py 对拍', () {
    for (final symbol in fixtureSymbols) {
      test(symbol, () {
        final bars = loadBars(symbol);
        final golden = (loadFixture('indicators_$symbol.json') as Map)
            .cast<String, Object?>();
        final actual =
            computeIndicators(bars, ['ma', 'ema', 'macd', 'rsi', 'lon']);

        for (final group in golden.keys) {
          final expectedSeries =
              (golden[group] as Map).cast<String, Object?>();
          final actualSeries = actual[group];
          expect(actualSeries, isNotNull, reason: 'missing group $group');
          for (final name in expectedSeries.keys) {
            final expectedValues = (expectedSeries[name] as List)
                .map((value) => value == null ? null : (value as num).toDouble())
                .toList();
            final actualValues = actualSeries![name];
            expect(actualValues, isNotNull,
                reason: 'missing series $group.$name');
            expect(actualValues!.length, expectedValues.length,
                reason: '$group.$name length');
            for (var index = 0; index < expectedValues.length; index++) {
              expectClose(actualValues[index], expectedValues[index],
                  '$symbol $group.$name[$index]');
            }
          }
        }
      });
    }
  });
}
