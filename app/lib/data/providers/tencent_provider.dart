/// 腾讯行情数据源，移植自 backend/app/providers/tencent_adapter.py。
/// A 股实时行情（GBK 文本协议）与日 K / 分钟 K。
library;

import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:fast_gbk/fast_gbk.dart';

import '../../models/models.dart';
import '../provider_error.dart';
import '../symbol_utils.dart';

class TencentProvider {
  static const source = 'tencent';

  final Dio _dio;

  TencentProvider([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              headers: {
                'User-Agent': 'Mozilla/5.0',
                'Referer': 'https://gu.qq.com/',
              },
            ));

  String _marketSymbol(String symbol) {
    final clean = normalizeSymbol(symbol);
    switch (guessMarket(clean)) {
      case 'SH':
        return 'sh$clean';
      case 'SZ':
        return 'sz$clean';
      case 'BJ':
        return 'bj$clean';
    }
    throw ProviderError('Unsupported market for symbol $symbol', source);
  }

  Future<List<Quote>> realtimeQuotes(List<String> symbols) async {
    if (symbols.isEmpty) return [];
    final marketSymbols = symbols.map(_marketSymbol).join(',');
    final Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        'https://qt.gtimg.cn/q=$marketSymbols',
        options: Options(responseType: ResponseType.bytes),
      );
    } on DioException catch (exc) {
      throw ProviderError(exc.message ?? exc.toString(), source);
    }
    if (response.statusCode != 200) {
      throw ProviderError('HTTP ${response.statusCode}', source);
    }
    final text = gbk.decode(response.data ?? const [], allowMalformed: true);
    return _parseRealtimeText(text);
  }

  Future<List<KlineBar>> kline(
    String symbol,
    String period, {
    String? start,
    String? end,
    String adjust = 'qfq',
  }) async {
    final clean = _marketSymbol(symbol);
    if (period != 'day' && period != 'week' && period != 'month') {
      final periodKey = _minutePeriodKey(period);
      final payload = await _getJson(
        'https://ifzq.gtimg.cn/appstock/app/kline/mkline',
        {'param': '$clean,$periodKey,,${_minuteCount(period)}'},
      );
      return _parseMinutePayload(payload, clean, periodKey);
    }

    final count = _estimateCount(start, end);
    final adjustKey =
        const {'none': '', 'qfq': 'qfq', 'hfq': 'hfq'}[adjust] ?? 'qfq';
    final payload = await _getJson(
      'https://ifzq.gtimg.cn/appstock/app/fqkline/get',
      {'param': '$clean,$period,${start ?? ''},${end ?? ''},$count,$adjustKey'},
    );
    return _parseKlinePayload(payload, clean, adjustKey, period);
  }

  /// 腾讯接口 content-type 为 text/html，需手动 JSON 解析
  Future<Map<String, dynamic>> _getJson(
      String url, Map<String, String> params) async {
    final Response<String> response;
    try {
      response = await _dio.get<String>(url,
          queryParameters: params,
          options: Options(responseType: ResponseType.plain));
    } on DioException catch (exc) {
      throw ProviderError(exc.message ?? exc.toString(), source);
    }
    if (response.statusCode != 200) {
      throw ProviderError('HTTP ${response.statusCode}', source);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.data ?? '');
    } on FormatException catch (exc) {
      throw ProviderError('invalid json: ${exc.message}', source);
    }
    if (decoded is! Map<String, dynamic>) {
      throw ProviderError('unexpected payload', source);
    }
    if (decoded['code'] != 0) {
      throw ProviderError('${decoded['msg'] ?? decoded}', source);
    }
    return decoded;
  }
}

String _formatTradeTime(String value) {
  if (value.length != 14) return value;
  final digits = RegExp(r'^\d{14}$');
  if (!digits.hasMatch(value)) return value;
  return '${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)}'
      ' ${value.substring(8, 10)}:${value.substring(10, 12)}:${value.substring(12, 14)}';
}

double? _slashValue(String value, int index) {
  final parts = value.split('/');
  if (parts.length <= index) return null;
  return safeDouble(parts[index]);
}

List<Quote> _parseRealtimeText(String text) {
  final quotes = <Quote>[];
  for (final chunk in text.split('\n')) {
    if (!chunk.contains('="')) continue;
    final eq = chunk.indexOf('=');
    final rawSymbol = chunk.substring(0, eq);
    var payload = chunk.substring(eq + 1).trim();
    payload = payload.replaceAll(RegExp(r'^"+|[";]+$'), '');
    final fields = payload.split('~');
    if (fields.length < 39 || fields[2].isEmpty) continue;
    final prefixed = rawSymbol.replaceAll('v_', '');
    final symbol = normalizeSymbol(fields[2]);
    quotes.add(Quote(
      symbol: symbol,
      market: prefixed.startsWith('bj') ? 'BJ' : guessMarket(symbol),
      name: fields[1],
      tradeTime: _formatTradeTime(fields[30]),
      price: safeDouble(fields[3]),
      open: safeDouble(fields[5]),
      high: safeDouble(fields[33]),
      low: safeDouble(fields[34]),
      preClose: safeDouble(fields[4]),
      pctChg: safeDouble(fields[32]),
      change: safeDouble(fields[31]),
      volume: safeDouble(fields[36]),
      amount: _slashValue(fields[35], 2) ?? safeDouble(fields[37]),
      turnover: safeDouble(fields[38]),
      // 腾讯 f[45] = 总市值（亿元），对齐 tencent_adapter.py
      marketCap: fields.length > 45 ? safeDouble(fields[45]) : null,
    ));
  }
  return quotes;
}

int _estimateCount(String? start, String? end) {
  if (start == null || start.isEmpty) return 640;
  final startDate = DateTime.tryParse(start);
  if (startDate == null) return 640;
  final endDate =
      (end != null ? DateTime.tryParse(end) : null) ?? DateTime.now();
  final days = math.max(endDate.difference(startDate).inDays, 1);
  // 腾讯 fqkline 的 count 上限约 1200+（超限返回 param error 且 data 为列表），
  // 封顶留余量（对齐 backend tencent_adapter._estimate_count）
  return math.min(math.max((days * 1.6).ceil(), 120), 1100);
}

String _minutePeriodKey(String period) {
  const periodMap = {
    '1m': 'm1',
    '5m': 'm5',
    '15m': 'm15',
    '30m': 'm30',
    '60m': 'm60',
  };
  final key = periodMap[period];
  if (key == null) {
    throw ProviderError('Unsupported period $period', TencentProvider.source);
  }
  return key;
}

int _minuteCount(String period) {
  if (period == '1m') return 1000;
  if (period == '5m') return 600;
  return 320;
}

String _formatMinuteTime(String value) {
  final digits = RegExp(r'^\d{12}$');
  if (!digits.hasMatch(value)) return value;
  return '${value.substring(0, 4)}-${value.substring(4, 6)}-${value.substring(6, 8)}'
      ' ${value.substring(8, 10)}:${value.substring(10, 12)}:00';
}

List<KlineBar> _normalizeRows(
    Iterable<dynamic> rows, double? initialPreviousClose, String Function(String) formatTime) {
  final bars = <KlineBar>[];
  var previousClose = initialPreviousClose;
  for (final row in rows) {
    if (row is! List || row.length < 6) continue;
    final close = safeDouble(row[2]);
    double? pctChg;
    if (close != null && previousClose != null && previousClose != 0) {
      pctChg = (close - previousClose) / previousClose * 100;
    }
    bars.add(KlineBar(
      time: formatTime('${row[0]}'),
      open: safeDouble(row[1]),
      high: safeDouble(row[3]),
      low: safeDouble(row[4]),
      close: close,
      volume: safeDouble(row[5]),
      pctChg: pctChg,
    ));
    if (close != null) previousClose = close;
  }
  final byTime = <String, KlineBar>{};
  for (final bar in bars) {
    if (bar.time.isEmpty) continue;
    byTime.putIfAbsent(bar.time, () => bar);
  }
  return byTime.values.toList()..sort((a, b) => a.time.compareTo(b.time));
}

List<KlineBar> _parseKlinePayload(Map<String, dynamic> payload,
    String marketSymbol, String adjustKey, String period) {
  final data =
      (payload['data'] as Map<String, dynamic>?)?[marketSymbol] as Map<String, dynamic>? ??
          const {};
  final key = adjustKey.isNotEmpty ? '$adjustKey$period' : period;
  final rows =
      (data[key] ?? data['qfq$period'] ?? data[period] ?? const []) as List;
  return _normalizeRows(rows, null, (value) => value);
}

List<KlineBar> _parseMinutePayload(
    Map<String, dynamic> payload, String marketSymbol, String periodKey) {
  final data =
      (payload['data'] as Map<String, dynamic>?)?[marketSymbol] as Map<String, dynamic>? ??
          const {};
  final rows = (data[periodKey] ?? const []) as List;
  final previousClose = safeDouble(data['prec']);
  return _normalizeRows(rows, previousClose, _formatMinuteTime);
}
