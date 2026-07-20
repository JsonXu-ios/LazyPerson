/// 技术指标计算，移植自 backend/app/indicators.py。
/// 空值语义与 pandas 一致：输入 null 视为 NaN 并传播，输出用 null 表示无值。
library;

import '../models/models.dart';

List<double> _closes(List<KlineBar> bars) =>
    bars.map((bar) => bar.close ?? double.nan).toList();

List<double?> _seal(List<double> values) =>
    values.map((value) => value.isNaN ? null : value).toList();

/// rolling(window).mean()，min_periods = window（含 NaN 的窗口输出 NaN）
List<double> _rollingMean(List<double> values, int window) {
  final result = List<double>.filled(values.length, double.nan);
  for (var i = window - 1; i < values.length; i++) {
    var sum = 0.0;
    var valid = true;
    for (var j = i - window + 1; j <= i; j++) {
      if (values[j].isNaN) {
        valid = false;
        break;
      }
      sum += values[j];
    }
    if (valid) result[i] = sum / window;
  }
  return result;
}

/// pandas ewm(span, adjust=False).mean()
List<double> _ewm(List<double> values, int span) {
  final alpha = 2 / (span + 1);
  final result = List<double>.filled(values.length, double.nan);
  double? previous;
  for (var i = 0; i < values.length; i++) {
    final value = values[i];
    if (value.isNaN) {
      if (previous != null) result[i] = previous;
      continue;
    }
    previous = previous == null ? value : alpha * value + (1 - alpha) * previous;
    result[i] = previous;
  }
  return result;
}

Map<String, List<double?>> computeMa(List<KlineBar> bars,
    {List<int> windows = const [5, 10, 20, 60]}) {
  final close = _closes(bars);
  return {
    for (final window in windows) 'ma$window': _seal(_rollingMean(close, window)),
  };
}

Map<String, List<double?>> computeEma(List<KlineBar> bars,
    {List<int> spans = const [12, 26]}) {
  final close = _closes(bars);
  return {for (final span in spans) 'ema$span': _seal(_ewm(close, span))};
}

Map<String, List<double?>> computeMacd(List<KlineBar> bars,
    {int fast = 12, int slow = 26, int signal = 9}) {
  final close = _closes(bars);
  final emaFast = _ewm(close, fast);
  final emaSlow = _ewm(close, slow);
  final dif = List<double>.generate(close.length, (i) => emaFast[i] - emaSlow[i]);
  final dea = _ewm(dif, signal);
  final hist = List<double>.generate(close.length, (i) => (dif[i] - dea[i]) * 2);
  return {'dif': _seal(dif), 'dea': _seal(dea), 'hist': _seal(hist)};
}

List<double> _rsi(List<double> close, int window) {
  final gain = List<double>.filled(close.length, double.nan);
  final loss = List<double>.filled(close.length, double.nan);
  for (var i = 1; i < close.length; i++) {
    final delta = close[i] - close[i - 1];
    if (delta.isNaN) continue;
    gain[i] = delta > 0 ? delta : 0;
    loss[i] = delta < 0 ? -delta : 0;
  }
  final avgGain = _rollingMean(gain, window);
  final avgLoss = _rollingMean(loss, window);
  return List<double>.generate(close.length, (i) {
    final g = avgGain[i];
    final l = avgLoss[i];
    if (g.isNaN || l.isNaN || l == 0) return double.nan;
    final rs = g / l;
    return 100 - 100 / (1 + rs);
  });
}

Map<String, List<double?>> computeRsi(List<KlineBar> bars,
    {List<int> windows = const [6, 12, 24]}) {
  final close = _closes(bars);
  return {for (final window in windows) 'rsi$window': _seal(_rsi(close, window))};
}

/// 中式 SMA 递推（通达信 SMA(X, N, M)），NaN 沿用前值
List<double> _smaCn(List<double> values, int window, [int weight = 1]) {
  final result = List<double>.filled(values.length, double.nan);
  double? previous;
  for (var i = 0; i < values.length; i++) {
    final value = values[i];
    if (value.isNaN) {
      if (previous != null) result[i] = previous;
      continue;
    }
    previous = previous == null
        ? value
        : (weight * value + (window - weight) * previous) / window;
    result[i] = previous;
  }
  return result;
}

Map<String, List<double?>> computeLon(List<KlineBar> bars) {
  final length = bars.length;
  final close = _closes(bars);
  final high = bars.map((bar) => bar.high ?? double.nan).toList();
  final low = bars.map((bar) => bar.low ?? double.nan).toList();
  final volume = bars.map((bar) => bar.volume ?? double.nan).toList();

  final longSeries = List<double>.filled(length, double.nan);
  var cumulative = 0.0;
  for (var i = 0; i < length; i++) {
    double rc = double.nan;
    if (i >= 1) {
      final high2 = (high[i].isNaN || high[i - 1].isNaN)
          ? double.nan
          : (high[i] > high[i - 1] ? high[i] : high[i - 1]);
      final low2 = (low[i].isNaN || low[i - 1].isNaN)
          ? double.nan
          : (low[i] < low[i - 1] ? low[i] : low[i - 1]);
      final denominator = (high2 - low2) * 100;
      final volume2 = volume[i] + volume[i - 1];
      final vid = denominator == 0 ? double.nan : volume2 / denominator;
      rc = (close[i] - close[i - 1]) * vid;
    }
    cumulative += rc.isNaN ? 0 : rc;
    longSeries[i] = cumulative;
  }

  final dif = _smaCn(longSeries, 10, 1);
  final dea = _smaCn(longSeries, 20, 1);
  final lon = List<double>.generate(length, (i) => dif[i] - dea[i]);
  final lonma = _rollingMean(lon, 10);
  return {
    'lon': _seal(lon),
    'lonma': _seal(lonma),
    'dif': _seal(dif),
    'dea': _seal(dea),
  };
}

/// 对齐 indicators.py::compute_indicators
IndicatorPayload computeIndicators(List<KlineBar> bars, List<String> names) {
  final wanted = names.map((name) => name.trim().toLowerCase()).toSet();
  final result = <String, Map<String, List<double?>>>{};
  if (wanted.contains('ma')) result['ma'] = computeMa(bars);
  if (wanted.contains('ema')) result['ema'] = computeEma(bars);
  if (wanted.contains('macd')) result['macd'] = computeMacd(bars);
  if (wanted.contains('lon')) result['lon'] = computeLon(bars);
  if (wanted.contains('rsi')) result['rsi'] = computeRsi(bars);
  return result;
}
