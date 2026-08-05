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
  group('classifyGroup（分界 20/40/70/100/130/160/190/220）', () {
    test('低于 20 不入档', () {
      expect(classifyGroup(19.9), isNull);
      expect(classifyGroup(15.0), isNull); // 000408 场景
      expect(classifyGroup(-3.0), isNull);
      expect(classifyGroup(null), isNull);
    });

    test('一档 [20,40)：过 40 就交给二档（振江 25.37 场景）', () {
      expect(classifyGroup(20.0), 1);
      expect(classifyGroup(25.37), 1); // 振江
      expect(classifyGroup(35.0), 1);
      expect(classifyGroup(39.9), 1);
      expect(groupThreshold(1), 20.0);
    });

    test('二档 [40,70)：过 40 即从一档升为二档（利欧 41.71 场景）', () {
      expect(classifyGroup(40.0), 2);
      expect(classifyGroup(41.71), 2); // 利欧
      expect(classifyGroup(47.43), 2); // 600617
      expect(classifyGroup(55.0), 2);
      expect(classifyGroup(69.9), 2);
      expect(groupThreshold(2), 40.0);
    });

    test('八档下沿 20/40/70/100/130/160/190/220，区间 [本档下沿, 下一档下沿)', () {
      expect([for (var k = 1; k <= 8; k++) groupThreshold(k)],
          [20.0, 40.0, 70.0, 100.0, 130.0, 160.0, 190.0, 220.0]);
      expect(groupLower, [20.0, 40.0, 70.0, 100.0, 130.0, 160.0, 190.0, 220.0]);
      expect(classifyGroup(70.0), 3);
      expect(classifyGroup(99.9), 3);
      expect(classifyGroup(100.0), 4);
      expect(classifyGroup(130.0), 5);
      expect(classifyGroup(160.0), 6);
      expect(classifyGroup(190.0), 7);
      expect(classifyGroup(220.0), 8);
    });

    test('第八档没有上限', () {
      expect(classifyGroup(250.0), 8);
      expect(classifyGroup(500.0), 8);
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

    test('一档命中：pct=35% ∈ [20,40)，低点日在过线日之前', () {
      // 低点10 → 收盘依次 5%、12%、32%（首次收盘站上20主线），今日现价 13.5
      final raw = _makeWaveBars(today, closesPct: [5, 12, 32]);
      final bars = _seal(raw);
      final row = evaluateStock('600001', '测试股', 13.5, bars, today: today);
      expect(row, isNotNull);
      expect(row!.group, 1);
      expect(row.threshold, 20.0);
      expect(row.low90, 10.0);
      expect((row.pct * 10).round() / 10, 35.0);
      expect(row.lowDate.compareTo(row.crossDate), lessThan(0));
      // 首次收盘站上一档下沿20%的是 32% 那天（最后一根）
      expect(row.crossDate, bars[bars.length - 1].time);
      expect(row.fromTop, isFalse); // 峰值就是现价，没有回落
    });

    test('利欧场景：pct=41.7% → 过 40 升为二档', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [10, 28, 38]));
      final row = evaluateStock('002131', '利欧场景', 14.17, bars, today: today);
      expect(row, isNotNull);
      expect(row!.group, 2);
      expect(row.threshold, 40.0);
      expect(row.fromTop, isFalse);
    });

    test('振江场景：pct=25.4% → 一档命中', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [5, 12, 18]));
      final row = evaluateStock('603507', '振江场景', 12.54, bars, today: today);
      expect(row, isNotNull);
      expect(row!.group, 1);
      expect(row.threshold, 20.0);
    });

    test('000408 场景：现价只到 15% 不命中', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [5, 12, 14]));
      expect(
          evaluateStock('000408', '测试股', 11.5, bars, today: today), isNull);
    });

    test('二档命中：pct=55% ∈ [40,70)，过下沿即入', () {
      final raw = _makeWaveBars(today, closesPct: [20, 42, 52]);
      final bars = _seal(raw);
      final row = evaluateStock('600001', '测试股', 15.5, bars, today: today);
      expect(row, isNotNull);
      expect(row!.group, 2);
      expect(row.threshold, 40.0);
      // 首次收盘站上二档入档线40%的是 42% 那天（倒数第二根）
      expect(row.crossDate, bars[bars.length - 2].time);
    });

    test('三档命中：pct=75% ∈ [70,100)', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [20, 45, 72]));
      final row = evaluateStock('600001', '测试股', 17.5, bars, today: today);
      expect(row, isNotNull);
      expect(row!.group, 3);
      expect(row.threshold, 70.0);
      expect(row.fromTop, isFalse);
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

  group('isFallingBack（历史最高档 > 当前档）', () {
    test('冲到更高档后掉回低档区间 → 回落；重新站上该档下沿即恢复', () {
      // 冲到 45%（二档）后回落到 35%（一档区间）→ 回落
      expect(isFallingBack(35.0, 45.0), isTrue);
      // 重新站上 40% → 恢复为二档，不再算回落
      expect(isFallingBack(41.0, 45.0), isFalse);
      // 一路上行、现价即峰值 → 不是回落
      expect(isFallingBack(35.0, 35.0), isFalse);
      expect(isFallingBack(45.0, 45.0), isFalse);
      // 档内回落（48→41 都在二档）→ 不算
      expect(isFallingBack(41.0, 48.0), isFalse);
      // 三档跌回二档 → 回落
      expect(isFallingBack(65.0, 75.0), isTrue);
    });

    test('任一侧未入档 → 不是回落', () {
      expect(isFallingBack(null, 45.0), isFalse);
      expect(isFallingBack(15.0, 45.0), isFalse); // 现价没入档，本就不会命中
      expect(isFallingBack(35.0, null), isFalse);
    });

    test('收盘走出 20%→45%→45%、现价 35%：二档回落到一档区间 → 打 fromTop 标记不丢弃', () {
      final bars =
          _seal(_makeWaveBars(_defaultToday, closesPct: [20, 45, 45]));
      final row =
          evaluateStock('000938', '冲高回落', 13.5, bars, today: _defaultToday);
      expect(row, isNotNull);
      expect(row!.group, 1);
      expect(row.fromTop, isTrue);
    });

    test('峰值 90% 现价 92% 仍在三档 → 第三档保留且无标记', () {
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
      expect(hit.lonOk, isFalse);
      expect(hit.northOk, isFalse);
    });

    test('去掉的 strong/板块字段不再出现在 toJson 里', () {
      final json = const BandHit(
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
      ).toJson();
      expect(json.containsKey('strong'), isFalse);
      expect(json.containsKey('industry'), isFalse);
      expect(json.containsKey('concepts'), isFalse);
      expect(json.containsKey('hot_sector'), isFalse);
    });

    test('旧持久化数据带 strong/板块字段也能读（多余键忽略）', () {
      final hit = BandHit.fromJson(const {
        'symbol': '600519',
        'price': 1361.76,
        'low90': 1000.0,
        'pct': 36.18,
        'group': 1,
        'threshold': 20.0,
        'over': 16.18,
        'max_pct': 36.18,
        'strong': true,
        'industry': '白酒Ⅱ',
        'concepts': ['酿酒概念'],
        'hot_sector': true,
      });
      expect(hit.symbol, '600519');
      expect(hit.group, 1);
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
        revenueOk: true,
        lonOk: true,
        northOk: true,
        fromTop: true,
      ).toJson());
      expect(hit.dividendRecent, isTrue);
      expect(hit.profitOk, isTrue);
      expect(hit.revenueOk, isTrue);
      expect(hit.lonOk, isTrue);
      expect(hit.northOk, isTrue);
      expect(hit.fromTop, isTrue);
    });
  });

  group('isNorthBound（一路北上）', () {
    List<KlineBar> windowWith(double lowPos, double highPos, {int n = 60}) {
      final bars = <KlineBar>[];
      var day = DateTime(2026, 4, 1);
      while (bars.length < n) {
        if (day.weekday != DateTime.saturday && day.weekday != DateTime.sunday) {
          bars.add(KlineBar(
              time: day.toIso8601String().substring(0, 10),
              open: 10.0,
              high: 10.2,
              low: 9.9,
              close: 10.1));
        }
        day = day.add(const Duration(days: 1));
      }
      final lowI = ((n - 1) * lowPos).floor();
      final highI = ((n - 1) * highPos).floor();
      final list = bars
          .asMap()
          .entries
          .map((e) => KlineBar(
              time: e.value.time,
              open: e.value.open,
              high: e.key == highI ? 15.0 : e.value.high,
              low: e.key == lowI ? 8.0 : e.value.low,
              close: e.value.close))
          .toList();
      return list;
    }

    int lowIndexOf(List<KlineBar> w) {
      var li = 0;
      for (var i = 1; i < w.length; i++) {
        if (w[i].low! < w[li].low!) li = i;
      }
      return li;
    }

    test('低点在前1/3、最高点在后1/3 → true（中间回落不限）', () {
      final w = windowWith(0.1, 0.9);
      expect(isNorthBound(w, lowIndexOf(w)), isTrue);
    });

    test('低点在后段（V型反转类）→ false', () {
      final w = windowWith(0.9, 0.95);
      expect(isNorthBound(w, lowIndexOf(w)), isFalse);
    });

    test('高点在中段（冲高后阴跌）→ false', () {
      final w = windowWith(0.1, 0.5);
      expect(isNorthBound(w, lowIndexOf(w)), isFalse);
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
