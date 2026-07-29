/// 东方财富数据源（efinance 的底层 HTTP 接口）。
/// 承担：沪深全市场清单/快照（clist 分页）、单只 K 线兜底。
library;

import 'package:dio/dio.dart';

import '../../models/models.dart';
import '../provider_error.dart';
import '../symbol_utils.dart';

class MarketSnapshotPage {
  final List<Quote> quotes;
  final int total;

  const MarketSnapshotPage({required this.quotes, required this.total});
}

class EastmoneyProvider {
  static const source = 'eastmoney';

  /// 沪主板 m:1+t:2 / 科创板 m:1+t:23 / 深主板 m:0+t:6 / 创业板 m:0+t:80。
  /// 不含北交所。
  static const _shSzMarkets = 'm:0+t:6,m:0+t:80,m:1+t:2,m:1+t:23';
  static const pageSize = 100;

  final Dio _dio;

  EastmoneyProvider([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              headers: {'User-Agent': 'Mozilla/5.0'},
            ));

  /// clist 主备域名：push2 在部分网络下 TLS 不通，push2delay 提供同一接口
  static const _clistHosts = [
    'https://push2.eastmoney.com',
    'https://push2delay.eastmoney.com',
  ];

  /// 全市场快照单页。page 从 1 开始；返回该页行情与总数。
  Future<MarketSnapshotPage> fullMarketSnapshotPage(int page) async {
    final payload = await _getJsonWithFallback(
      _clistHosts,
      '/api/qt/clist/get',
      {
        'pn': '$page',
        'pz': '$pageSize',
        'po': '0',
        'np': '1',
        'fltt': '2',
        'invt': '2',
        'fid': 'f12',
        'fs': _shSzMarkets,
        'fields': 'f2,f3,f4,f5,f6,f8,f12,f13,f14,f15,f16,f17,f18,f20,f124',
      },
    );
    final data = payload['data'];
    if (data is! Map<String, dynamic>) {
      return const MarketSnapshotPage(quotes: [], total: 0);
    }
    final total = (data['total'] as num?)?.toInt() ?? 0;
    final diff = data['diff'];
    final rows = diff is List
        ? diff
        : diff is Map<String, dynamic>
            ? diff.values.toList()
            : const [];
    final quotes = <Quote>[];
    for (final row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final symbol = '${row['f12'] ?? ''}'.trim();
      if (symbol.isEmpty) continue;
      final market = row['f13'] == 1 ? 'SH' : 'SZ';
      final tradeTs = (row['f124'] as num?)?.toInt();
      quotes.add(Quote(
        symbol: symbol,
        market: market,
        name: '${row['f14'] ?? ''}'.trim(),
        tradeTime: tradeTs != null && tradeTs > 0
            ? DateTime.fromMillisecondsSinceEpoch(tradeTs * 1000)
                .toIso8601String()
                .replaceFirst('T', ' ')
                .substring(0, 19)
            : null,
        price: safeDouble(row['f2']),
        open: safeDouble(row['f17']),
        high: safeDouble(row['f15']),
        low: safeDouble(row['f16']),
        preClose: safeDouble(row['f18']),
        pctChg: safeDouble(row['f3']),
        change: safeDouble(row['f4']),
        volume: safeDouble(row['f5']),
        amount: safeDouble(row['f6']),
        turnover: safeDouble(row['f8']),
        marketCap: marketCapYi(safeDouble(row['f20'])),
      ));
    }
    return MarketSnapshotPage(quotes: quotes, total: total);
  }

  /// 拉全市场快照（约 55 页）。onProgress(已拉行数, 总数) 用于进度展示。
  Future<List<Quote>> fullMarketSnapshot(
      {void Function(int loaded, int total)? onProgress}) async {
    final all = <Quote>[];
    var page = 1;
    var total = 0;
    while (true) {
      final result = await fullMarketSnapshotPage(page);
      total = result.total;
      all.addAll(result.quotes);
      onProgress?.call(all.length, total);
      if (result.quotes.isEmpty || all.length >= total) break;
      page += 1;
      if (page > 200) break;
    }
    return all;
  }

  String _secid(String symbol) {
    final clean = normalizeSymbol(symbol);
    switch (guessMarket(clean)) {
      case 'SH':
        return '1.$clean';
      case 'SZ':
      case 'BJ':
        return '0.$clean';
    }
    throw ProviderError('Unsupported market for symbol $symbol', source);
  }

  Future<List<KlineBar>> kline(
    String symbol,
    String period, {
    String? start,
    String? end,
    String adjust = 'qfq',
  }) async {
    const kltMap = {
      '1m': '1',
      '5m': '5',
      '15m': '15',
      '30m': '30',
      '60m': '60',
      'day': '101',
      'week': '102',
      'month': '103',
    };
    const fqtMap = {'none': '0', 'qfq': '1', 'hfq': '2'};
    final klt = kltMap[period];
    if (klt == null) throw ProviderError('Unsupported period $period', source);

    final payload = await _getJson(
      'https://push2his.eastmoney.com/api/qt/stock/kline/get',
      {
        'secid': _secid(symbol),
        'klt': klt,
        'fqt': fqtMap[adjust] ?? '1',
        'beg': (start ?? '19900101').replaceAll('-', ''),
        'end': (end ?? '20500101').replaceAll('-', ''),
        'fields1': 'f1,f2,f3,f4,f5,f6',
        'fields2': 'f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61',
        'rtntype': '6',
      },
    );
    final data = payload['data'];
    if (data is! Map<String, dynamic>) return const [];
    final klines = (data['klines'] as List?) ?? const [];
    final bars = <KlineBar>[];
    for (final line in klines) {
      final parts = '$line'.split(',');
      if (parts.length < 11) continue;
      bars.add(KlineBar(
        time: parts[0],
        open: safeDouble(parts[1]),
        close: safeDouble(parts[2]),
        high: safeDouble(parts[3]),
        low: safeDouble(parts[4]),
        volume: safeDouble(parts[5]),
        amount: safeDouble(parts[6]),
        pctChg: safeDouble(parts[8]),
        turnover: safeDouble(parts[10]),
      ));
    }
    bars.sort((a, b) => a.time.compareTo(b.time));
    return bars;
  }

  Future<Map<String, dynamic>> _getJsonWithFallback(
      List<String> hosts, String path, Map<String, String> params) async {
    ProviderError? lastError;
    for (final host in hosts) {
      try {
        return await _getJson('$host$path', params);
      } on ProviderError catch (exc) {
        lastError = exc;
      }
    }
    throw lastError ?? const ProviderError('no host available', source);
  }

  Future<Map<String, dynamic>> _getJson(
      String url, Map<String, String> params) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _dio.get<Map<String, dynamic>>(url,
          queryParameters: params);
    } on DioException catch (exc) {
      throw ProviderError(exc.message ?? exc.toString(), source);
    }
    if (response.statusCode != 200) {
      throw ProviderError('HTTP ${response.statusCode}', source);
    }
    return response.data ?? const {};
  }
}
