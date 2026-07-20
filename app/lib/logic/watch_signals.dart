/// 自选信号（大涨回撤 / 上升±3%），移植自 frontend/src/App.tsx 的
/// analyzeWatchSignal 与 hasLargeRiseThenDrawdown。
library;

import '../models/models.dart';
import 'auto_drawing.dart';
import 'calendar_window.dart';
import 'market_panels.dart';

class WatchSignal {
  final String symbol;
  final String name;

  const WatchSignal({required this.symbol, required this.name});
}

class WatchSignalResult {
  final WatchSignal signal;
  final bool drawdown;
  final bool uptrend;

  const WatchSignalResult({
    required this.signal,
    required this.drawdown,
    required this.uptrend,
  });
}

WatchSignalResult analyzeWatchSignal(
  WatchlistItem item,
  KlinePayload payload, {
  DateTime? todayUtc,
}) {
  final config = panelConfig(panelForAsset(
    symbol: item.symbol,
    market: item.market,
    groupName: item.groupName,
    note: item.note,
  ));
  final sliced = sliceDailyPayloadByCalendarDays(
    payload,
    config.windowDays,
    mode: config.windowMode,
  );
  final bars = (sliced?.bars ?? const <KlineBar>[])
      .where((bar) => bar.high != null && bar.low != null && bar.close != null)
      .toList();
  final signal = WatchSignal(
    symbol: item.symbol,
    name: item.name.isNotEmpty ? item.name : item.symbol,
  );
  if (bars.length < 20) {
    return WatchSignalResult(signal: signal, drawdown: false, uptrend: false);
  }

  final drawdown = hasLargeRiseThenDrawdown(bars);
  final auto = computeAutoDrawing(
    bars,
    windowSize: config.windowDays,
    levelStep: config.lineStep,
    extendLevelsBeyond100: config.extendLevelsBeyond100,
    todayUtc: todayUtc,
  );
  final latestPct = bars.last.pctChg ?? 0;
  final uptrend = latestPct.abs() <= 3 &&
      (auto?.trendSegments.any((segment) =>
              segment.direction == AutoTrendDirection.up &&
              segment.end.index >= bars.length - 12) ??
          false);
  return WatchSignalResult(signal: signal, drawdown: drawdown, uptrend: uptrend);
}

bool hasLargeRiseThenDrawdown(List<KlineBar> bars) {
  if (bars.isEmpty) return false;
  var troughPrice = bars.first.low ?? double.nan;
  var troughIndex = 0;
  var bestPeakPrice = 0.0;
  var bestPeakIndex = -1;
  var bestRisePct = 0.0;

  for (var index = 0; index < bars.length; index++) {
    final low = bars[index].low ?? double.nan;
    final high = bars[index].high ?? double.nan;
    if (low.isFinite && low < troughPrice) {
      troughPrice = low;
      troughIndex = index;
    }
    if (!high.isFinite || index <= troughIndex || troughPrice <= 0) continue;
    final risePct = (high - troughPrice) / troughPrice * 100;
    if (risePct > bestRisePct) {
      bestRisePct = risePct;
      bestPeakPrice = high;
      bestPeakIndex = index;
    }
  }

  final latestClose = bars.last.close ?? double.nan;
  if (bestPeakIndex < 0 || !latestClose.isFinite || bestPeakPrice <= 0) return false;
  final drawdownPct = (bestPeakPrice - latestClose) / bestPeakPrice * 100;
  return bestRisePct >= 30 && drawdownPct >= 20;
}
