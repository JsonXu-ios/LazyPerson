import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/logic/auto_drawing.dart';
import 'package:lazyperson/logic/level_rules.dart';
import 'package:lazyperson/models/models.dart';

AutoLineLevel _level(int percent) => AutoLineLevel(
    label: percent == 0 ? '0%' : '+$percent%', percent: percent, price: 10.0 + percent);

void main() {
  group('isMajorLevel / isHighlightLevel（A 股面板参数）', () {
    // A 股：majorLineStep 30, majorLineAnchor 20 → 主线 20/50/80/110/…/230
    test('20 起每 30 一档为主线', () {
      for (final percent in [20, 50, 80, 110, 140, 170, 200, 230]) {
        expect(
            isMajorLevel(_level(percent),
                majorLineStep: 30, majorLineAnchor: 20),
            isTrue,
            reason: '+$percent%');
      }
      for (final percent in [10, 30, 40, 60, 70, 90, 100, 120, 130]) {
        expect(
            isMajorLevel(_level(percent),
                majorLineStep: 30, majorLineAnchor: 20),
            isFalse,
            reason: '+$percent%');
      }
      expect(isMajorLevel(_level(0), majorLineStep: 30, majorLineAnchor: 20),
          isFalse);
    });

    test('anchor 以下不算主线', () {
      expect(isMajorLevel(_level(10), majorLineStep: 30, majorLineAnchor: 20),
          isFalse);
      expect(
          isMajorLevel(_level(110),
              majorLineStep: 30, majorLineMinPercent: 120, majorLineAnchor: 20),
          isFalse);
    });

    test('+20/+50/+80 与 0% 固定高亮', () {
      for (final percent in [0, 20, 50, 80]) {
        expect(
            isHighlightLevel(_level(percent),
                majorLineStep: 30, majorLineAnchor: 20),
            isTrue,
            reason: '+$percent%');
      }
      expect(
          isHighlightLevel(_level(30),
              majorLineStep: 30, majorLineAnchor: 20),
          isFalse);
    });
  });

  group('线条颜色', () {
    test('主线每档固定专属色（20/50/80/110/…/230）', () {
      const expected = {
        20: '#f24d4d',
        50: '#1f6feb',
        80: '#ffffff',
        110: '#c084fc',
        140: '#f2a93b',
        170: '#00a884',
        200: '#38bdf8',
        230: '#f472b6',
      };
      expected.forEach((percent, color) {
        expect(
            levelLineColor(_level(percent), '#f6d36b',
                majorLineStep: 30, majorLineAnchor: 20),
            color,
            reason: '+$percent%');
      });
      // 细线不受影响，仍用用户配置色
      expect(
          levelLineColor(_level(30), '#abcdef',
              majorLineStep: 30, majorLineAnchor: 20),
          '#abcdef');
    });

    test('标签文字明暗：浅底（白/琥珀/青）深色字，其余白字', () {
      for (final percent in [80, 140, 200]) {
        expect(majorLevelTextColor(percent), '#07111f', reason: '+$percent%');
      }
      for (final percent in [20, 50, 110, 170, 230]) {
        expect(majorLevelTextColor(percent), '#ffffff', reason: '+$percent%');
      }
    });
  });

  group('avoidCrowdedLevelLabels', () {
    LevelLabelRow row(String key, double top,
            {double priority = 50, bool highlight = false}) =>
        LevelLabelRow(
          key: key,
          label: key,
          color: '#fff',
          textColor: '#000',
          top: top,
          highlight: highlight,
          priority: priority,
        );

    test('高优先级保留，间距不足的低优先级被丢弃', () {
      final result = avoidCrowdedLevelLabels([
        row('a', 100, priority: 90),
        row('b', 110, priority: 50), // 距 a 10 < 19，被挤掉
        row('c', 130, priority: 50), // 距 a 30，保留
      ]);
      expect(result.map((item) => item.key).toList(), ['a', 'c']);
    });

    test('结果按 top 升序返回', () {
      final result = avoidCrowdedLevelLabels([
        row('low', 200, priority: 90),
        row('high', 50, priority: 60),
      ]);
      expect(result.map((item) => item.key).toList(), ['high', 'low']);
    });
  });

  group('shouldUseLogPriceScale', () {
    test('目标/基准 >= 2 或档位过多时启用', () {
      AutoDrawing drawing(double base, double target, int levelCount) =>
          AutoDrawing(
            direction: AutoTrendDirection.flat,
            windowSize: 60,
            latest: const KlineBar(time: '2026-01-01'),
            recentHigh: AutoPoint(time: '', price: target, index: 0),
            recentLow: AutoPoint(time: '', price: base, index: 0),
            base: AutoAnchor(time: '', price: base, label: ''),
            target: AutoAnchor(time: '', price: target, label: ''),
            levels: List.generate(levelCount, (i) => _level(i * 10)),
            trendSegments: const [],
            nearestLevel: null,
            nearestDistancePct: null,
          );

      expect(shouldUseLogPriceScale(null), isFalse);
      expect(shouldUseLogPriceScale(drawing(10, 25, 5)), isTrue);
      expect(shouldUseLogPriceScale(drawing(10, 15, 5)), isFalse);
      expect(shouldUseLogPriceScale(drawing(10, 15, 28)), isTrue);
    });
  });
}
