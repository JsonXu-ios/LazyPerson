/// 数值/文案格式化，移植自 frontend/src/utils/format.ts。
library;

import '../models/models.dart';

String formatNumber(double? value, {int digits = 2}) {
  if (value == null || value.isNaN) return '-';
  if (value.abs() >= 100000000) {
    return '${(value / 100000000).toStringAsFixed(2)}亿';
  }
  if (value.abs() >= 10000) return '${(value / 10000).toStringAsFixed(2)}万';
  return value.toStringAsFixed(digits);
}

String formatPercent(double? value) {
  if (value == null || value.isNaN) return '-';
  return '${value.toStringAsFixed(2)}%';
}

/// KlineChart.tsx::formatFullPrice
String formatFullPrice(double? value) {
  if (value == null || value.isNaN) return '-';
  if (value.abs() >= 100) return value.toStringAsFixed(2);
  if (value.abs() >= 1) return value.toStringAsFixed(3);
  return value.toStringAsFixed(6);
}

String formatTime(String? value) {
  if (value == null || value.isEmpty) return '-';
  return value.replaceAll('T', ' ').replaceAll('+08:00', '');
}

String qualityText(DataQuality? quality) {
  if (quality == null) return '未同步';
  if (quality.message.isNotEmpty) return quality.message;
  final cache = quality.fromCache ? '缓存' : '实时';
  return '${quality.source} · $cache${quality.stale ? ' · 过期' : ''}';
}

String normalizeError(Object? error) {
  final message = error?.toString() ?? '';
  return message.isNotEmpty ? message : '请求失败，请稍后重试';
}

String quoteName(String symbol, String? name) =>
    name != null && name.trim().isNotEmpty ? name : symbol;
