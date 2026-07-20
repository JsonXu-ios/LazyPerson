/// 日历/бар 窗口切片，移植自 frontend/src/utils/calendarWindow.ts。
library;

import '../models/models.dart';

enum WindowMode { calendar, bars }

KlinePayload? sliceDailyPayloadByCalendarDays(
  KlinePayload? payload,
  int days, {
  WindowMode mode = WindowMode.calendar,
}) {
  if (payload == null || payload.period != 'day' || payload.bars.isEmpty) {
    return payload;
  }

  final latestDate = _parseBarDate(payload.bars.last.time);
  if (latestDate == null) return payload;

  final cutoff = latestDate.subtract(Duration(days: days));
  final keepWeekends = _isCryptoSymbol(payload.symbol);

  final validItems = <({KlineBar bar, int index, DateTime date})>[];
  for (var index = 0; index < payload.bars.length; index++) {
    final bar = payload.bars[index];
    final date = _parseBarDate(bar.time);
    if (date == null || (!keepWeekends && !_isWeekday(date))) continue;
    if (!bar.hasOhlc) continue;
    validItems.add((bar: bar, index: index, date: date));
  }

  final selected = mode == WindowMode.bars
      ? validItems.sublist(
          validItems.length > days ? validItems.length - days : 0)
      : validItems
          .where((item) =>
              item.date.isAfter(cutoff) || item.date.isAtSameMomentAs(cutoff))
          .toList();

  if (selected.isEmpty || selected.length == payload.bars.length) {
    return payload;
  }

  final indices = selected.map((item) => item.index).toList();
  return payload.copyWith(
    bars: selected.map((item) => item.bar).toList(),
    indicators: _sliceIndicators(payload.indicators, indices),
  );
}

DateTime? _parseBarDate(String value) {
  final normalized =
      value.contains(' ') ? value.replaceFirst(' ', 'T') : '${value}T00:00:00';
  return DateTime.tryParse(normalized);
}

bool _isWeekday(DateTime date) =>
    date.weekday != DateTime.saturday && date.weekday != DateTime.sunday;

bool _isCryptoSymbol(String symbol) => symbol.toUpperCase().endsWith('-USD');

IndicatorPayload _sliceIndicators(IndicatorPayload indicators, List<int> indices) {
  return indicators.map((group, series) => MapEntry(
        group,
        series.map((name, values) => MapEntry(
              name,
              indices
                  .map((index) => index < values.length ? values[index] : null)
                  .toList(),
            )),
      ));
}
