/// 布局溢出回归测试。字号调大后最容易出的问题是 RenderFlex overflow，
/// 而 flutter analyze 抓不到 —— 只有真正 pump 一遍才知道。
/// 两个宽度都跑：411dp（设计稿基准）和 360dp（常见的窄屏 Android）。
///
/// 只覆盖纯展示 widget：整屏（HomeScreen / BandScanScreen）的 pumpWidget 会卡在
/// controller.bootstrap() 的异步上，fake_async 永远 settle 不了。整屏的横向溢出
/// 改为在 widget 里结构性堵住（顶栏、页头的长文本一律 Flexible + ellipsis）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/logic/band_scanner.dart';
import 'package:lazyperson/theme/app_theme.dart';
import 'package:lazyperson/ui/widgets/band_hit_card.dart';
import 'package:lazyperson/ui/widgets/band_radar.dart';

/// 设计稿基准宽 + 常见窄屏
const _sizes = <String, Size>{
  '411x880': Size(411, 880),
  '360x800': Size(360, 800),
};

BandHit _hit({
  String symbol = '600001',
  String name = '某某科技股份',
  bool limitUp = false,
  bool fromTop = false,
}) {
  return BandHit(
    symbol: symbol,
    name: name,
    price: 1361.76,
    low90: 1008.12,
    pct: 35.1,
    group: 1,
    threshold: 20,
    over: 15.1,
    maxPct: 38.4,
    lowDate: '2026-04-15',
    crossDate: '2026-05-20',
    limitUp: limitUp,
    fromTop: fromTop,
  );
}

Future<void> _pumpAt(
  WidgetTester tester,
  Size size,
  Widget child,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(theme: buildAppTheme(), home: child));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  _sizes.forEach((label, size) {
    group('$label 不溢出', () {
      testWidgets('命中卡（长名称 + 涨停 + 两个形态标记）', (tester) async {
        await _pumpAt(
          tester,
          size,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                BandHitCard(
                  hit: _hit(limitUp: true, fromTop: true),
                  index: 0,
                  onTap: () {},
                ),
                BandHitCard(
                  hit: _hit(
                      symbol: '600002', name: '名字特别长的一家上市公司股份有限公司'),
                  index: 1,
                  onTap: () {},
                ),
              ],
            ),
          ),
        );
      });

      testWidgets('命中卡：名称很短时涨幅仍然贴右', (tester) async {
        // 曾经写成 Flexible(名称) + Spacer，两者都是 flex 1、空间五五分，
        // 名称短的时候 Flexible 用不完的那截留在中间，涨幅就浮在半路上
        await _pumpAt(
          tester,
          size,
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: BandHitCard(
                hit: _hit(name: '中兴'),
                index: 0,
                onTap: () {},
              ),
            ),
          ),
        );

        final cardRight = tester.getBottomRight(find.byType(BandHitCard)).dx;
        final pctRight = tester.getBottomRight(find.text('+35.1%')).dx;

        // 只应剩卡片自己的右内边距（13dp）
        expect(cardRight - pctRight, lessThan(20));
      });

      testWidgets('八档雷达（八档都有命中）', (tester) async {
        await _pumpAt(
          tester,
          size,
          Scaffold(
            body: BandRadar(
              counts: const {1: 128, 2: 64, 3: 32, 4: 16, 5: 8, 6: 4, 7: 2, 8: 1},
              activeGroup: 3,
              onSelect: (_) {},
              visibleTotal: 255,
              allTotal: 512,
            ),
          ),
        );
      });
    });
  });
}
