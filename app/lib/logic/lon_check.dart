/// 八档局 LON 多头判定（纯函数），数值语义对齐
/// backend/app/lon_check.py::lon_trend_ok。
library;

import 'dart:math' as math;

/// 单周期判定：lon、lonma 都比上一根高（整体向上），且最新一根
/// lonma 不压在 lon 上面（lon ≥ lonma）。
/// 取最后两对非空值判定；有效值不足两对视为不通过。
bool lonTrendOk(List<double?> lon, List<double?> lonma) {
  final pairs = <(double, double)>[];
  final length = math.min(lon.length, lonma.length);
  for (var i = 0; i < length; i++) {
    final a = lon[i];
    final b = lonma[i];
    if (a != null && b != null) pairs.add((a, b));
  }
  if (pairs.length < 2) return false;
  final (prevLon, prevMa) = pairs[pairs.length - 2];
  final (lastLon, lastMa) = pairs[pairs.length - 1];
  return lastLon > prevLon && lastMa > prevMa && lastLon >= lastMa;
}
