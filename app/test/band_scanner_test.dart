/// 八档局纯逻辑单测，数值断言与 tests/test_scanner.py 对齐。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/logic/band_scanner.dart';
import 'package:lazyperson/models/models.dart';

class _Bar {
  String time;
  double? open;
  double? high;
  double? low;
  double? close;

  _Bar(this.time, {this.open, this.high, this.low, this.close});

  KlineBar toKline() =>
      KlineBar(time: time, open: open, high: high, low: low, close: close);
}

List<KlineBar> _seal(List<_Bar> bars) =>
    bars.map((bar) => bar.toKline()).toList();

final _defaultToday = DateTime(2026, 7, 24); // 周五

/// 生成 days 个自然日内的工作日日线，最低价 low 放在最早一根，其余为 low*1.05
List<_Bar> _makeBars(int days, double low, [DateTime? today]) {
  final base = today ?? _defaultToday;
  final bars = <_Bar>[];
  for (var offset = days; offset >= 0; offset--) {
    final day = base.subtract(Duration(days: offset));
    if (day.weekday == DateTime.saturday || day.weekday == DateTime.sunday) {
      continue;
    }
    final value = bars.isEmpty ? low : low * 1.05;
    bars.add(_Bar(
      day.toIso8601String().substring(0, 10),
      open: value,
      high: value * 1.02,
      low: value,
      close: value * 1.01,
    ));
  }
  return bars;
}

/// 构造 200 天日线：前段平台，波段低点在倒数第 closesPct.length+1 根，
/// 之后每日收盘按 closesPct 相对低点的涨幅走（低点→高点，时间顺序）
List<_Bar> _makeWaveBars(DateTime today,
    {double low = 10.0, List<double> closesPct = const []}) {
  final bars = _makeBars(200, low * 1.02, today);
  for (final bar in bars) {
    bar.low = low * 1.05;
    bar.close = low * 1.06;
    bar.high = low * 1.08;
    bar.open = low * 1.05;
  }
  final tail = closesPct.length;
  bars[bars.length - tail - 1].low = low; // 波段低点
  for (var offset = 0; offset < closesPct.length; offset++) {
    final bar = bars[bars.length - (tail - offset)];
    final price = low * (1 + closesPct[offset] / 100);
    bar.close = price;
    bar.high = price * 1.01;
    bar.low = bar.low! < price ? bar.low : price;
    bar.open = price * 0.99;
  }
  return bars;
}

void main() {
  group('classifyGroup', () {
    test('低于 20 不入档', () {
      expect(classifyGroup(19.9), isNull);
      expect(classifyGroup(15.0), isNull); // 000408 场景
      expect(classifyGroup(-3.0), isNull);
      expect(classifyGroup(null), isNull);
    });

    test('一档需站上30确认：[30,40)；过20未到30不入档（振江 25.37 场景）', () {
      expect(classifyGroup(30.0), 1);
      expect(classifyGroup(31.0), 1);
      expect(classifyGroup(39.9), 1);
      expect(classifyGroup(25.37), isNull);
      expect(classifyGroup(20.0), isNull);
      expect(classifyGroup(29.9), isNull);
      expect(groupThreshold(1), 20.0);
      expect(groupEntryLine(1), 30.0);
    });

    test('40 是奇点：[40,50) 不入档（利欧 41.71/600617 47.43 场景）', () {
      expect(classifyGroup(40.0), isNull);
      expect(classifyGroup(41.71), isNull);
      expect(classifyGroup(47.43), isNull);
      expect(classifyGroup(49.9), isNull);
    });

    test('二档及以上过主线即入：[50,70)', () {
      expect(classifyGroup(50.0), 2);
      expect(classifyGroup(55.0), 2);
      expect(classifyGroup(66.0), 2); // 紫光66%回归二档
      expect(classifyGroup(69.9), 2);
      expect(groupThreshold(2), 50.0);
      expect(groupEntryLine(2), 50.0);
    });

    test('奇点后的过渡区不入档', () {
      expect(classifyGroup(70.0), isNull);
      expect(classifyGroup(75.0), isNull);
      expect(classifyGroup(105.0), isNull);
      expect(classifyGroup(135.0), isNull);
    });

    test('八档主线 20 起每 30 一档', () {
      expect([for (var k = 1; k <= 8; k++) groupThreshold(k)],
          [20.0, 50.0, 80.0, 110.0, 140.0, 170.0, 200.0, 230.0]);
      expect(classifyGroup(80.0), 3);
      expect(classifyGroup(99.9), 3);
      expect(classifyGroup(110.0), 4);
      expect(classifyGroup(125.0), 4);
      expect(classifyGroup(150.0), 5);
      expect(classifyGroup(181.0), 6);
      expect(classifyGroup(215.0), 7);
      expect(classifyGroup(241.0), 8);
    });

    test('超过八档上限（250%）不入档', () {
      expect(classifyGroup(249.9), 8);
      expect(classifyGroup(250.0), isNull);
      expect(classifyGroup(500.0), isNull);
    });
  });

  group('eligibleSymbol', () {
    test('沪深主板保留', () {
      for (final symbol in ['600519', '601398', '000001', '002138']) {
        expect(eligibleSymbol(symbol, '正常股'), isTrue, reason: symbol);
      }
    });

    test('创业板/科创板/北交所排除', () {
      expect(eligibleSymbol('300750', '创业板股'), isFalse);
      expect(eligibleSymbol('688981', '科创板股'), isFalse);
      expect(eligibleSymbol('430047', '北交所股'), isFalse);
      expect(eligibleSymbol('830799', '北交所股'), isFalse);
    });

    test('ST 排除（大小写/带星号）', () {
      expect(eligibleSymbol('600519', 'ST 某某'), isFalse);
      expect(eligibleSymbol('600519', '*ST某某'), isFalse);
      expect(eligibleSymbol('600519', 'st某某'), isFalse);
    });
  });

  group('sliceScanWindow', () {
    test('按自然日截取窗口', () {
      final bars = _seal(_makeBars(200, 10.0));
      final window = sliceScanWindow(bars, days: 90);
      final first = DateTime.parse(window.first.time);
      final last = DateTime.parse(window.last.time);
      expect(last.difference(first).inDays, lessThanOrEqualTo(90));
      expect(window.last.time, bars.last.time);
    });

    test('剔除 OHLC 缺失 bar', () {
      final raw = _makeBars(30, 10.0);
      raw[5].close = null;
      final window = sliceScanWindow(_seal(raw), days: 90);
      expect(window.every((bar) => bar.close != null), isTrue);
    });
  });

  group('isLimitUp', () {
    test('现价 == round(昨收×1.1, 2) 才算涨停', () {
      expect(isLimitUp(13.1, 11.91), isTrue); // 13.1 = round(11.91×1.1, 2)
      expect(isLimitUp(11.0, 10.0), isTrue); // 10.00 → 11.00
      expect(isLimitUp(13.42, 12.20), isTrue); // 12.20 → 13.42
      expect(isLimitUp(10.99, 10.0), isFalse); // 差一分不算
      expect(isLimitUp(null, 10.0), isFalse);
      expect(isLimitUp(11.0, null), isFalse);
      expect(isLimitUp(11.0, 0), isFalse);
    });
  });

  group('evaluateStock', () {
    final today = _defaultToday;

    test('一档命中：pct=35% ∈ [30,40)，低点日在过线日之前', () {
      // 低点10 → 收盘依次 5%、12%、32%（首次收盘站上30入档线），今日现价 13.5
      final raw = _makeWaveBars(today, closesPct: [5, 12, 32]);
      final bars = _seal(raw);
      final row = evaluateStock('600001', '测试股', 13.5, bars, today: today);
      expect(row, isNotNull);
      expect(row!.group, 1);
      expect(row.threshold, 20.0);
      expect(row.low90, 10.0);
      expect((row.pct * 10).round() / 10, 35.0);
      expect(row.lowDate.compareTo(row.crossDate), lessThan(0));
      // 首次收盘站上一档入档线30%的是 32% 那天（最后一根）
      expect(row.crossDate, bars[bars.length - 1].time);
    });

    test('利欧场景：pct=41.7% 在奇点后、未站上50 → 不命中', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [10, 28, 38]));
      expect(evaluateStock('002131', '利欧场景', 14.17, bars, today: today),
          isNull);
    });

    test('振江场景：pct=25.4% 刚过主线不足 10 点不命中', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [5, 12, 18]));
      expect(evaluateStock('603507', '振江场景', 12.54, bars, today: today),
          isNull);
    });

    test('000408 场景：现价只到 15% 不命中', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [5, 12, 14]));
      expect(
          evaluateStock('000408', '测试股', 11.5, bars, today: today), isNull);
    });

    test('二档命中：pct=55% ∈ [50,70)，过主线即入', () {
      final raw = _makeWaveBars(today, closesPct: [20, 42, 52]);
      final bars = _seal(raw);
      final row = evaluateStock('600001', '测试股', 15.5, bars, today: today);
      expect(row, isNotNull);
      expect(row!.group, 2);
      expect(row.threshold, 50.0);
      // 首次收盘站上二档入档线50%的是 52% 那天（最后一根）
      expect(row.crossDate, bars[bars.length - 1].time);
    });

    test('低点是最后一天不命中（无低点→高点波段）', () {
      final raw = _makeBars(200, 10.0, today);
      for (final bar in raw) {
        bar.low = 12.0;
      }
      raw.last.low = 10.0; // 今日砸出新低
      expect(evaluateStock('600001', '测试股', 12.5, _seal(raw), today: today),
          isNull);
    });

    test('上市不足 90 天不命中', () {
      final bars = _seal(_makeBars(60, 10.0, today));
      expect(
          evaluateStock('600001', '新股', 13.1, bars, today: today), isNull);
    });

    test('无最新价不命中', () {
      final bars = _seal(_makeBars(200, 10.0, today));
      expect(
          evaluateStock('600001', '停牌股', null, bars, today: today), isNull);
    });

    test('有效日线不足 20 根不命中', () {
      final bars = _seal(_makeBars(200, 10.0, today)).sublist(0, 10);
      expect(
          evaluateStock('600001', '测试股', 13.1, bars, today: today), isNull);
    });
  });

  group('isFallingFromTop（跌破主线标记）', () {
    test('只看主线 20/50/80/…，收回即恢复', () {
      // 曾到 85%（站上80主线），现价 65%/75% 跌破 → true
      expect(isFallingFromTop(65.0, 85.0), isTrue);
      expect(isFallingFromTop(75.0, 85.0), isTrue);
      // 峰值 85% 回踩到 82%：仍站在 80 上方 → false
      expect(isFallingFromTop(82.0, 85.0), isFalse);
      // 紫光场景：峰值 79.9（摸过70奇点），现价 66 ≥ 60 → false
      expect(isFallingFromTop(66.0, 79.9), isFalse);
      // 冲过 50 主线（峰值66.3）又跌回 49.7% → true（002774 场景）
      expect(isFallingFromTop(49.7, 66.3), isTrue);
      // 跌回后重新站上 50 → 恢复
      expect(isFallingFromTop(52.0, 66.3), isFalse);
      // 峰值45摸过40奇点 → 地板30，31 ≥ 30 → false
      expect(isFallingFromTop(31.0, 45.0), isFalse);
      expect(isFallingFromTop(45.0, 45.0), isFalse);
      expect(isFallingFromTop(22.0, 35.0), isFalse);
    });

    test('盘中冲过奇点后深回落 → 异常回落（闰土场景）', () {
      // 收盘峰值65.5、盘中冲高71.7（摸过70奇点），现56.8 < 60 → true
      expect(isFallingFromTop(56.8, 65.5, 71.7), isTrue);
      // 回落守在 60~70 区间 → false
      expect(isFallingFromTop(63.0, 65.5, 71.7), isFalse);
      // 盘中最高 69.9 没摸到 70：地板只有主线 50 → false
      expect(isFallingFromTop(56.8, 65.5, 69.9), isFalse);
      // 摸过 40 奇点后跌回 30 以下 → true
      expect(isFallingFromTop(28.0, 35.0, 41.7), isTrue);
      expect(isFallingFromTop(32.0, 35.0, 41.7), isFalse);
    });

    test('收盘走出 40%→85%→65%：曾站上80现跌破 → 打 fromTop 标记不丢弃', () {
      final bars =
          _seal(_makeWaveBars(_defaultToday, closesPct: [40, 85, 65]));
      final row =
          evaluateStock('000938', '冲高回落', 16.5, bars, today: _defaultToday);
      expect(row, isNotNull);
      expect(row!.group, 2);
      expect(row.fromTop, isTrue);
    });

    test('峰值 90% 现价 92% 仍站在 80 上方 → 第三档保留且无标记', () {
      final bars =
          _seal(_makeWaveBars(_defaultToday, closesPct: [40, 85, 90]));
      final row =
          evaluateStock('600001', '持稳股', 19.2, bars, today: _defaultToday);
      expect(row, isNotNull);
      expect(row!.group, 3);
      expect(row.maxPct, greaterThanOrEqualTo(90.0));
      expect(row.fromTop, isFalse);
    });
  });

  group('BandHit 序列化', () {
    test('旧持久化数据缺 dividend_recent/profit_ok 字段默认 false', () {
      final hit = BandHit.fromJson(const {
        'symbol': '600519',
        'name': '贵州茅台',
        'price': 1361.76,
        'low90': 1000.0,
        'pct': 36.18,
        'group': 1,
        'threshold': 20.0,
        'over': 16.18,
        'max_pct': 36.18,
        'low_date': '2026-05-06',
        'cross_date': '2026-07-01',
      });
      expect(hit.dividendRecent, isFalse);
      expect(hit.profitOk, isFalse);
    });

    test('标记字段随 toJson/fromJson 往返', () {
      final hit = BandHit.fromJson(const BandHit(
        symbol: '600519',
        name: '贵州茅台',
        price: 1361.76,
        low90: 1000.0,
        pct: 36.18,
        group: 1,
        threshold: 20.0,
        over: 16.18,
        maxPct: 36.18,
        lowDate: '2026-05-06',
        crossDate: '2026-07-01',
        dividendRecent: true,
        profitOk: true,
      ).toJson());
      expect(hit.dividendRecent, isTrue);
      expect(hit.profitOk, isTrue);
    });
  });

  group('V 型反弹不再排除（低点可以是反转也可以是起点）', () {
    final today = _defaultToday;

    test('前段 40% 高平台 → 跌到低点 → 反弹 35% → 正常入一档（利欧类深跌反转）', () {
      final bars = _makeBars(200, 10.0, today);
      for (final bar in bars) {
        bar.low = 14.0;
        bar.open = 14.0;
        bar.close = 14.0;
        bar.high = 14.2;
      }
      final lowBar = bars[bars.length - 4];
      lowBar.low = 10.0;
      lowBar.close = 10.2;
      lowBar.open = 10.5;
      lowBar.high = 10.6;
      for (final offset in [3, 2, 1]) {
        final bar = bars[bars.length - offset];
        bar.low = 10.5;
        bar.open = 13.0;
        bar.close = 13.2;
        bar.high = 13.3;
      }
      final row =
          evaluateStock('600001', '深跌反转', 13.5, _seal(bars), today: today);
      expect(row, isNotNull);
      expect(row!.group, 1);
    });

    test('低点在窗口前段的上行波段不受影响', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [5, 12, 32]));
      final row = evaluateStock('600001', '上行波段', 13.5, bars, today: today);
      expect(row, isNotNull);
      expect(row!.fromTop, isFalse);
    });
  });
}
