/// 市场面板配置与资产归类，移植自 frontend/src/App.tsx。
library;

import 'calendar_window.dart';

enum PanelKey { aShare, us, gold, crypto }

class MarketPanelConfig {
  final PanelKey key;
  final String label;
  final String fallback;
  final int windowDays;
  final WindowMode windowMode;
  final int lineStep;
  final int? majorLineStep;
  final double? majorLineMinPercent;
  final bool showLevelPrices;
  final bool extendLevelsBeyond100;

  const MarketPanelConfig({
    required this.key,
    required this.label,
    required this.fallback,
    required this.windowDays,
    this.windowMode = WindowMode.calendar,
    required this.lineStep,
    this.majorLineStep,
    this.majorLineMinPercent,
    this.showLevelPrices = false,
    this.extendLevelsBeyond100 = false,
  });

  /// 与网页版 loadDetailFor 的 dayLimit 规则一致
  int get dayLimit => windowDays == 180 ? 240 : 140;
}

const marketPanels = <MarketPanelConfig>[
  MarketPanelConfig(
    key: PanelKey.aShare,
    label: 'A 股',
    fallback: '002138',
    windowDays: 90,
    windowMode: WindowMode.calendar,
    lineStep: 10,
    majorLineStep: 20,
    majorLineMinPercent: 100,
    showLevelPrices: true,
    extendLevelsBeyond100: true,
  ),
  MarketPanelConfig(
    key: PanelKey.us,
    label: '美股',
    fallback: 'SPY',
    windowDays: 180,
    windowMode: WindowMode.bars,
    lineStep: 5,
    majorLineStep: 10,
    showLevelPrices: true,
    extendLevelsBeyond100: true,
  ),
  MarketPanelConfig(
    key: PanelKey.gold,
    label: '黄金',
    fallback: 'GC=F',
    windowDays: 180,
    windowMode: WindowMode.bars,
    lineStep: 5,
    majorLineStep: 10,
    showLevelPrices: true,
    extendLevelsBeyond100: true,
  ),
  MarketPanelConfig(
    key: PanelKey.crypto,
    label: '比特币',
    fallback: 'BTC-USD',
    windowDays: 180,
    windowMode: WindowMode.bars,
    lineStep: 5,
    majorLineStep: 10,
    showLevelPrices: true,
    extendLevelsBeyond100: true,
  ),
];

MarketPanelConfig panelConfig(PanelKey key) =>
    marketPanels.firstWhere((panel) => panel.key == key, orElse: () => marketPanels.first);

final _usSymbolPattern = RegExp(r'^[A-Z]{1,5}$');

/// 资产归入哪个面板，移植自 App.tsx::panelForAsset
PanelKey panelForAsset({
  required String symbol,
  required String market,
  String? groupName,
  String note = '',
}) {
  switch (groupName) {
    case 'a_share':
      return PanelKey.aShare;
    case 'us':
      return PanelKey.us;
    case 'gold':
      return PanelKey.gold;
    case 'crypto':
      return PanelKey.crypto;
  }

  final upperSymbol = symbol.toUpperCase();
  final upperMarket = market.toUpperCase();
  if (upperMarket == 'CRYPTO' || upperSymbol.endsWith('-USD') || note.contains('比特币')) {
    return PanelKey.crypto;
  }
  if (upperMarket == 'FUT' ||
      upperMarket == 'FX' ||
      upperSymbol == 'GC=F' ||
      upperSymbol == 'GLD' ||
      upperSymbol == 'XAUUSD=X' ||
      note.contains('黄金')) {
    return PanelKey.gold;
  }
  if (upperMarket == 'US' || _usSymbolPattern.hasMatch(upperSymbol)) {
    return PanelKey.us;
  }
  return PanelKey.aShare;
}

/// PanelKey 与 sqlite group_name 的映射
String panelGroupName(PanelKey key) {
  switch (key) {
    case PanelKey.aShare:
      return 'a_share';
    case PanelKey.us:
      return 'us';
    case PanelKey.gold:
      return 'gold';
    case PanelKey.crypto:
      return 'crypto';
  }
}
