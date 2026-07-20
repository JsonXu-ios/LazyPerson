import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/logic/auto_drawing.dart';
import 'package:lazyperson/logic/calendar_window.dart';
import 'package:lazyperson/logic/watch_signals.dart';
import 'package:lazyperson/models/models.dart';

import 'fixtures_util.dart';

KlineBar _bar(int day, double low, double high, double close,
    {double? pctChg}) {
  final date =
      DateTime(2026, 1, 1).add(Duration(days: day)).toIso8601String();
  return KlineBar(
    time: date.substring(0, 10),
    open: (low + high) / 2,
    high: high,
    low: low,
    close: close,
    volume: 1000,
    pctChg: pctChg,
  );
}

void main() {
  group('hasLargeRiseThenDrawdown', () {
    test('空列表与不足样本返回 false', () {
      expect(hasLargeRiseThenDrawdown([]), isFalse);
      expect(hasLargeRiseThenDrawdown([_bar(0, 10, 11, 10.5)]), isFalse);
    });

    test('先涨 50% 再回撤 25% 触发', () {
      final bars = <KlineBar>[
        for (var i = 0; i < 10; i++) _bar(i, 10, 10.5, 10.2),
        for (var i = 10; i < 20; i++)
          _bar(i, 10 + (i - 10) * 0.5, 10.5 + (i - 10) * 0.5, 10.2 + (i - 10) * 0.5),
        _bar(20, 14.8, 15.0, 15.0), // 高点 15 = +50%
        for (var i = 21; i < 26; i++) _bar(i, 11.0, 11.5, 11.25), // 回撤 25%
      ];
      expect(hasLargeRiseThenDrawdown(bars), isTrue);
    });

    test('涨幅不足 30% 不触发', () {
      final bars = <KlineBar>[
        for (var i = 0; i < 10; i++) _bar(i, 10, 10.5, 10.2),
        _bar(10, 11.9, 12.0, 12.0), // +20%
        for (var i = 11; i < 15; i++) _bar(i, 9.0, 9.5, 9.2),
      ];
      expect(hasLargeRiseThenDrawdown(bars), isFalse);
    });

    test('回撤不足 20% 不触发', () {
      final bars = <KlineBar>[
        for (var i = 0; i < 10; i++) _bar(i, 10, 10.5, 10.2),
        _bar(10, 14.8, 15.0, 15.0), // +50%
        for (var i = 11; i < 15; i++) _bar(i, 13.0, 13.5, 13.5), // 回撤 10%
      ];
      expect(hasLargeRiseThenDrawdown(bars), isFalse);
    });
  });

  group('analyzeWatchSignal', () {
    test('bars 少于 20 时两个信号都为 false', () {
      final bars = [for (var i = 0; i < 10; i++) _bar(i, 10, 11, 10.5)];
      final result = analyzeWatchSignal(
        const WatchlistItem(symbol: '000001', market: 'SZ', groupName: 'a_share'),
        KlinePayload(symbol: '000001', period: 'day', bars: bars),
      );
      expect(result.drawdown, isFalse);
      expect(result.uptrend, isFalse);
      expect(result.signal.symbol, '000001');
    });

    test('name 为空时信号名回退到 symbol', () {
      final result = analyzeWatchSignal(
        const WatchlistItem(symbol: '600519', market: 'SH', groupName: 'a_share'),
        const KlinePayload(symbol: '600519', period: 'day'),
      );
      expect(result.signal.name, '600519');
    });

    test('uptrend 与 golden 通道方向一致（真实数据对拍）', () {
      for (final symbol in fixtureSymbols) {
        final bars = loadBars(symbol);
        final payload =
            KlinePayload(symbol: symbol, period: 'day', bars: bars);
        final item = WatchlistItem(
            symbol: symbol, market: 'SZ', name: symbol, groupName: 'a_share');
        final result = analyzeWatchSignal(item, payload);

        // 期望值按同一定义独立推导（切片 + 通道方向 + 最新涨跌幅）
        final sliced = sliceDailyPayloadByCalendarDays(payload, 90,
            mode: WindowMode.calendar)!;
        final valid = sliced.bars
            .where((bar) =>
                bar.high != null && bar.low != null && bar.close != null)
            .toList();
        final auto = computeAutoDrawing(valid,
            windowSize: 90, levelStep: 10, extendLevelsBeyond100: true);
        final latestPct = valid.last.pctChg ?? 0;
        final expectUptrend = latestPct.abs() <= 3 &&
            (auto?.trendSegments.any((segment) =>
                    segment.direction == AutoTrendDirection.up &&
                    segment.end.index >= valid.length - 12) ??
                false);
        expect(result.uptrend, expectUptrend, reason: symbol);
      }
    });
  });
}
