import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/logic/auto_drawing.dart';
import 'package:lazyperson/logic/calendar_window.dart';
import 'package:lazyperson/models/models.dart';

import 'fixtures_util.dart';

void main() {
  group('calendarWindow + autoDrawing 与网页版 TS 对拍（A 股面板参数）', () {
    for (final symbol in fixtureSymbols) {
      test(symbol, () {
        final bars = loadBars(symbol);
        final golden = (loadFixture('auto_drawing_$symbol.json') as Map)
            .cast<String, Object?>();

        final payload = KlinePayload(
            symbol: symbol, period: 'day', adjust: 'qfq', bars: bars);
        final sliced = sliceDailyPayloadByCalendarDays(payload, 90,
            mode: WindowMode.calendar)!;
        final expectedTimes =
            (golden['slicedTimes'] as List).map((value) => '$value').toList();
        expect(sliced.bars.map((bar) => bar.time).toList(), expectedTimes,
            reason: '$symbol slicedTimes');

        final actual = computeAutoDrawing(
          sliced.bars,
          windowSize: 90,
          levelStep: 10,
          extendLevelsBeyond100: true,
        );
        final expected =
            (golden['autoDrawing'] as Map?)?.cast<String, Object?>();
        if (expected == null) {
          expect(actual, isNull);
          return;
        }
        expect(actual, isNotNull);

        expect(actual!.direction.name, expected['direction']);
        expect(actual.windowSize, expected['windowSize']);
        _expectPoint(actual.recentHigh.toJson(), expected['recentHigh'],
            '$symbol recentHigh');
        _expectPoint(
            actual.recentLow.toJson(), expected['recentLow'], '$symbol recentLow');
        _expectAnchor(actual.base.toJson(), expected['base'], '$symbol base');
        _expectAnchor(
            actual.target.toJson(), expected['target'], '$symbol target');

        final expectedLevels = (expected['levels'] as List)
            .map((row) => (row as Map).cast<String, Object?>())
            .toList();
        expect(actual.levels.length, expectedLevels.length,
            reason: '$symbol levels length');
        for (var index = 0; index < expectedLevels.length; index++) {
          final level = actual.levels[index];
          expect(level.label, expectedLevels[index]['label']);
          expect(level.percent, expectedLevels[index]['percent']);
          expectClose(
              level.price,
              (expectedLevels[index]['price'] as num).toDouble(),
              '$symbol level ${level.label}');
        }

        final expectedSegments = (expected['trendSegments'] as List)
            .map((row) => (row as Map).cast<String, Object?>())
            .toList();
        expect(actual.trendSegments.length, expectedSegments.length,
            reason: '$symbol trendSegments length');
        for (var index = 0; index < expectedSegments.length; index++) {
          final segment = actual.trendSegments[index];
          final expectedSegment = expectedSegments[index];
          expect(segment.id, expectedSegment['id']);
          expect(segment.label, expectedSegment['label']);
          expect(segment.direction.name, expectedSegment['direction']);
          _expectPoint(segment.start.toJson(), expectedSegment['start'],
              '$symbol ${segment.id} start');
          _expectPoint(segment.end.toJson(), expectedSegment['end'],
              '$symbol ${segment.id} end');
        }

        final expectedNearest =
            (expected['nearestLevel'] as Map?)?.cast<String, Object?>();
        if (expectedNearest == null) {
          expect(actual.nearestLevel, isNull);
        } else {
          expect(actual.nearestLevel!.label, expectedNearest['label']);
          expectClose(
              actual.nearestLevel!.price,
              (expectedNearest['price'] as num).toDouble(),
              '$symbol nearestLevel');
        }
        expectClose(
            actual.nearestDistancePct,
            (expected['nearestDistancePct'] as num?)?.toDouble(),
            '$symbol nearestDistancePct');
      });
    }
  });
}

void _expectPoint(Map<String, Object?> actual, Object? expectedRaw, String context) {
  final expected = (expectedRaw as Map).cast<String, Object?>();
  expect(actual['time'], expected['time'], reason: '$context time');
  expect(actual['index'], expected['index'], reason: '$context index');
  expectClose(actual['price'] as double?,
      (expected['price'] as num?)?.toDouble(), '$context price');
}

void _expectAnchor(Map<String, Object?> actual, Object? expectedRaw, String context) {
  final expected = (expectedRaw as Map).cast<String, Object?>();
  expect(actual['time'], expected['time'], reason: '$context time');
  expect(actual['label'], expected['label'], reason: '$context label');
  expectClose(actual['price'] as double?,
      (expected['price'] as num?)?.toDouble(), '$context price');
}
