/// A 股画线参数，移植自 frontend/src/App.tsx。
/// 项目只做沪深 A 股，不再有市场面板切换（美股/黄金/加密已移除）。
library;

import 'calendar_window.dart';

class MarketConfig {
  final String label;
  final String fallback;
  final int windowDays;
  final WindowMode windowMode;
  final int lineStep;
  final int? majorLineStep;
  final double? majorLineMinPercent;
  final int majorLineAnchor;
  final bool showLevelPrices;
  final bool extendLevelsBeyond100;

  const MarketConfig({
    required this.label,
    required this.fallback,
    required this.windowDays,
    this.windowMode = WindowMode.calendar,
    required this.lineStep,
    this.majorLineStep,
    this.majorLineMinPercent,
    this.majorLineAnchor = 0,
    this.showLevelPrices = false,
    this.extendLevelsBeyond100 = false,
  });

  /// 与网页版 loadDetailFor 的 dayLimit 规则一致
  int get dayLimit => windowDays == 180 ? 240 : 140;
}

/// sqlite watchlist 的 group_name（历史数据里 A 股都写的是 a_share）
const aShareGroup = 'a_share';

const aShareConfig = MarketConfig(
  label: 'A 股',
  fallback: '002138',
  windowDays: 90,
  windowMode: WindowMode.calendar,
  lineStep: 10,
  // 粗线 = 20 起每 30 一档（20/50/80/110/…/230），对齐八档局主线
  majorLineStep: 30,
  majorLineAnchor: 20,
  showLevelPrices: true,
  extendLevelsBeyond100: true,
);
