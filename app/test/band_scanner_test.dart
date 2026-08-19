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

/// 构造"先高后低"的日线：平台在 low×1.2，中途一根冲到 low×(1+peakPct/100)，
/// 尾部第 [lowFromEnd] 根探到 low（窗口最低价），之后贴着低点横着。
List<_Bar> _makeFallBars(DateTime today,
    {double low = 10.0, double peakPct = 60, int lowFromEnd = 4}) {
  final bars = _makeBars(200, low * 1.2, today);
  for (final bar in bars) {
    bar.open = low * 1.2;
    bar.close = low * 1.2;
    bar.high = low * 1.22;
    bar.low = low * 1.18;
  }
  // 高点：低点之前 15 根
  final peakIndex = bars.length - lowFromEnd - 15;
  final peak = low * (1 + peakPct / 100);
  bars[peakIndex].close = peak;
  bars[peakIndex].high = peak * 1.01;
  bars[peakIndex].open = peak * 0.99;
  bars[peakIndex].low = peak * 0.98;
  // 低点及其后：贴着地板
  final lowIndex = bars.length - lowFromEnd - 1;
  bars[lowIndex].low = low;
  bars[lowIndex].close = low * 1.005;
  bars[lowIndex].open = low * 1.01;
  bars[lowIndex].high = low * 1.02;
  for (var i = lowIndex + 1; i < bars.length; i++) {
    bars[i].low = low * 1.002;
    bars[i].close = low * 1.008;
    bars[i].open = low * 1.006;
    bars[i].high = low * 1.015;
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
    test('旧持久化数据缺 dividend_recent/profit_ok 字段 = 未知（null）', () {
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
      // 三态：缺字段 = 未补充，不能当成"不达标"
      expect(hit.dividendRecent, isNull);
      expect(hit.profitOk, isNull);
      expect(hit.lonOk, isNull);
      expect(hit.marksKnown, isFalse);
      // northOk 是本地日K算出来的，没有三态问题
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

    test('低点在前、高点在后 → true', () {
      final w = windowWith(0.1, 0.9);
      expect(isNorthBound(w, lowIndexOf(w)), isTrue);
    });

    test('中途回撤超过30% → false', () {
      final w = windowWith(0.1, 0.9);
      final mid = w.length ~/ 2;
      final adjusted = [
        for (var i = 0; i < w.length; i++)
          KlineBar(
            time: w[i].time,
            open: w[i].open,
            high: w[i].high,
            low: w[i].low,
            close: i >= mid - 4 && i < mid
                ? 20.0
                : (i >= mid ? 13.0 : w[i].close),
          ),
      ];
      expect(isNorthBound(adjusted, lowIndexOf(adjusted)), isFalse);
    });

    test('中途回撤25%（未超阈值）→ true', () {
      final w = windowWith(0.1, 0.9);
      final mid = w.length ~/ 2;
      final adjusted = [
        for (var i = 0; i < w.length; i++)
          KlineBar(
            time: w[i].time,
            open: w[i].open,
            high: w[i].high,
            low: w[i].low,
            close: i >= mid - 4 && i < mid
                ? 20.0
                : (i >= mid ? 15.0 : w[i].close),
          ),
      ];
      expect(isNorthBound(adjusted, lowIndexOf(adjusted)), isTrue);
    });

    test('高点在低点之前（先见高点再跌）→ false', () {
      final w = windowWith(0.9, 0.3);
      expect(isNorthBound(w, lowIndexOf(w)), isFalse);
    });

    test('高点在中段但仍晚于低点 → true', () {
      final w = windowWith(0.1, 0.5);
      expect(isNorthBound(w, lowIndexOf(w)), isTrue);
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

  group('changeOverDays（近 N 日涨幅，任务 B）', () {
    /// 收盘 10,11,12,13,14，最后一根的日期由 [lastDay] 指定
    List<KlineBar> series(String lastDay) {
      const closes = [10.0, 11.0, 12.0, 13.0, 14.0];
      final end = DateTime.parse('${lastDay}T00:00:00');
      return [
        for (var i = 0; i < closes.length; i++)
          KlineBar(
            time: end
                .subtract(Duration(days: closes.length - 1 - i))
                .toIso8601String()
                .substring(0, 10),
            open: closes[i],
            high: closes[i],
            low: closes[i],
            close: closes[i],
          ),
      ];
    }

    final today = DateTime(2026, 7, 24);

    test('最后一根就是今天 → 基准取 closes[-(N+1)]（跳过今天那根）', () {
      // closes[-4] = 11 → 3 日涨幅 = 15/11-1
      expect(changeOverDays(series('2026-07-24'), 15.0, 3, today: today),
          closeTo(36.36, 0.01));
      // closes[-6] 不存在 → 数据不足
      expect(changeOverDays(series('2026-07-24'), 15.0, 5, today: today), isNull);
    });

    test('最后一根不是今天（盘前/休市）→ 基准取 closes[-N]', () {
      // closes[-3] = 12 → 15/12-1 = 25%
      expect(changeOverDays(series('2026-07-23'), 15.0, 3, today: today),
          closeTo(25.0, 0.001));
      // closes[-5] = 10 → 50%
      expect(changeOverDays(series('2026-07-23'), 15.0, 5, today: today),
          closeTo(50.0, 0.001));
    });

    test('数据不足 / 现价缺失 / 基准非正 → null', () {
      expect(changeOverDays(series('2026-07-23'), 15.0, 9, today: today), isNull);
      expect(changeOverDays(series('2026-07-23'), null, 3, today: today), isNull);
      expect(changeOverDays(const [], 15.0, 3, today: today), isNull);
      final zeroBase = [
        for (var i = 0; i < 4; i++)
          KlineBar(time: '2026-07-2${i + 1}', close: 0),
      ];
      expect(changeOverDays(zeroBase, 15.0, 3, today: today), isNull);
    });

    test('收盘缺失的 bar 不进序列（不会把基准挪错位）', () {
      final bars = [
        const KlineBar(time: '2026-07-17', close: 9),
        const KlineBar(time: '2026-07-20'), // 停牌，无收盘
        const KlineBar(time: '2026-07-21', close: 10),
        const KlineBar(time: '2026-07-22', close: 11),
        const KlineBar(time: '2026-07-23', close: 12),
      ];
      // 最后一根不是今天 → closes[-3] = 10
      expect(changeOverDays(bars, 15.0, 3, today: today), closeTo(50.0, 0.001));
    });

    test('evaluateStock 把 chg3/chg5 一起算进命中行', () {
      final bars = _seal(_makeWaveBars(today, closesPct: [5, 12, 32]));
      final row = evaluateStock('600001', '上行波段', 13.5, bars, today: today);
      expect(row, isNotNull);
      // 窗口最后一根是今天 → 3/5 日基准都落在 10.6 的平台上
      expect(row!.chg3, closeTo(27.36, 0.01));
      expect(row.chg5, closeTo(27.36, 0.01));
    });
  });
  group('breakoutStage（破势分组）', () {
    test('按已突破的最高主线分组，每只股只归最高一组', () {
      // 未过20 → 不入
      expect(breakoutStage(19.9), isNull);
      expect(breakoutStage(null), isNull);
      // 站上20没到50 → stage 1（破势页只展示 stage≥2）
      expect(breakoutStage(35.0), 1);
      // 站上50 → 「20→50」组
      expect(breakoutStage(50.0), 2);
      expect(breakoutStage(55.0), 2);
      expect(breakoutStage(79.9), 2);
      expect(breakoutStageLabel(2), '20→50');
      // 站上80 → 「50→80」组；115% 只算「80→110」，不重复计入前面
      expect(breakoutStage(80.0), 3);
      expect(breakoutStageLabel(3), '50→80');
      expect(breakoutStage(115.0), 4);
      expect(breakoutStageLabel(4), '80→110');
      expect(breakoutStage(250.0), 8);
      expect(breakoutStageLabel(8), '200→230');
    });

    test('evaluateStock 带上 breakStage（与档位口径互不影响）', () {
      final bars = _seal(_makeWaveBars(_defaultToday, closesPct: [20, 42, 52]));
      final row =
          evaluateStock('600001', '测试股', 15.5, bars, today: _defaultToday);
      expect(row, isNotNull);
      expect(row!.pct, greaterThan(50));
      expect(row.breakStage, 2); // 站上50主线 → 「20→50」
      expect(row.group, 2); // 档位口径下同样是二档（分界40）
    });
  });

  group('buildupOver（蓄势待发：刚过线）', () {
    test('刚站上某条主线、还没走远才算', () {
      // 还没过 20% 的不看
      expect(buildupOver(12.0), isNull);
      expect(buildupOver(null), isNull);
      expect(buildupOver(19.9), isNull);
      // 刚站上 20 线
      expect(buildupOver(20.0), closeTo(0, 1e-9));
      expect(buildupLine(23.5), 20);
      // 52 → 刚过 50，超出 2
      expect(buildupOver(52.0), closeTo(2.0, 1e-9));
      expect(buildupLine(52.0), 50);
      // 58 → 超出 8，已经走远
      expect(buildupOver(58.0), isNull);
      expect(buildupLine(58.0), isNull);
      // 46.5 还没站上 50，只算刚过 20 那条？不——20 早就过了，超出 26.5
      expect(buildupOver(46.5), isNull);
      // 刚过 80 / 刚过 230
      expect(buildupOver(81.0), closeTo(1.0, 1e-9));
      expect(buildupLine(232.0), 230);
      // 远高于最高主线
      expect(buildupOver(300.0), isNull);
    });

    test('阈值可调', () {
      expect(buildupOver(58.0, maxOver: 10), closeTo(8.0, 1e-9));
    });
  });

  group('evaluateZeroBase（零帧起手：从高处下来、停在 0 点）', () {
    final today = _defaultToday;

    test('先高后低、现价贴着 90 日低点 → 命中，group=0', () {
      final bars = _seal(_makeFallBars(today, peakPct: 60));
      final row = evaluateZeroBase('600001', '摔下来的', 10.1, bars, today: today);
      expect(row, isNotNull);
      expect(row!.group, 0); // 不属于八档任何一档
      expect(row.low90, closeTo(10.0, 1e-6));
      expect(row.pct, closeTo(1.0, 0.05)); // 停在 0 点附近
      expect(row.maxPct, closeTo(60.0, 0.5)); // 从 +60% 处下来的
      expect(row.crossDate.compareTo(row.lowDate), lessThan(0)); // 高点在低点之前
      // 同一只在八档局里是不命中的（pct < 20%），两边互斥
      expect(evaluateStock('600001', '摔下来的', 10.1, bars, today: today), isNull);
    });

    test('已经反弹走了（现价离低点 >3%）不算"停留在 0 点"', () {
      final bars = _seal(_makeFallBars(today, peakPct: 60));
      expect(evaluateZeroBase('600001', '反弹了', 10.5, bars, today: today), isNull);
      // 阈值可调
      expect(
          evaluateZeroBase('600001', '反弹了', 10.5, bars,
              today: today, maxPct: 8),
          isNotNull);
    });

    test('没从高处下来（高点不足 20%）不算', () {
      final bars = _seal(_makeFallBars(today, peakPct: 12));
      expect(evaluateZeroBase('600001', '平地股', 10.1, bars, today: today), isNull);
    });

    test('先低后高（一路北上）不算：高点必须在低点之前', () {
      // _makeWaveBars 是低点在前、之后一路涨 → 零帧起手不该命中
      final bars = _seal(_makeWaveBars(today, closesPct: [20, 42, 52]));
      expect(evaluateZeroBase('600001', '往上走', 10.1, bars, today: today), isNull);
    });

    test('按曾站上的最高主线分组（从多高摔下来）', () {
      expect(zeroBaseStage(60.0), 2); // 曾过 50
      expect(zeroBaseStage(25.0), 1); // 曾过 20
      expect(zeroBaseStage(115.0), 4); // 曾过 110
      expect(zeroBaseStage(15.0), isNull);
    });
  });
}
