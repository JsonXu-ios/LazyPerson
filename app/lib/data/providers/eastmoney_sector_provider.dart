/// 东方财富板块数据源。app 端手机网络下东财可达，所以三处取数都走东财
/// （后端因本机东财不稳，行业板块改走同花顺、个股概念走成分股反查，这里不需要）。
///
/// 实测通过的四个接口（2026-08 实测，push2 会 302 到 push2delay，两个域名互为主备）：
/// - 行业板块排行 clist  fs=m:90+t:2
/// - 概念板块排行 clist  fs=m:90+t:3
/// - 板块成分股   clist  fs=b:{板块代码}
/// - 个股所属板块 slist  spt=3&secid={0|1}.{code}
///   坑：fields 只写 f12,f13,f14,f3 时返回空 data；必须带上 f4，且 pn 从 1 开始
///   （pn=0 也返回空）。返回的是"全部所属板块"，行业/概念/地域混在一起，
///   需要用概念板块全集反查过滤（见 SectorService）。
/// - 个股行业     stock/get f127 直接给所属行业名（如"白酒Ⅱ"），一次请求搞定
library;

import 'package:dio/dio.dart';

import '../../models/models.dart';
import '../provider_error.dart';
import '../symbol_utils.dart';

/// clist 单页上限：pz 写超过 100 服务端也只给 100 行
const sectorPageSize = 100;

/// 行业板块
const sectorKindIndustry = 'industry';

/// 概念板块
const sectorKindConcept = 'concept';

String sectorFs(String kind) =>
    kind == sectorKindConcept ? 'm:90+t:3' : 'm:90+t:2';

/// clist 板块排行响应 → SectorBoard 列表（已按涨幅降序，服务端 fid=f3 排的）
List<SectorBoard> parseSectorBoards(Map<String, dynamic> payload, String kind) {
  return [
    for (final row in _diffRows(payload))
      if ('${row['f12'] ?? ''}'.trim().isNotEmpty)
        SectorBoard(
          code: '${row['f12']}'.trim(),
          name: '${row['f14'] ?? ''}'.trim(),
          kind: kind,
          pctChg: safeDouble(row['f3']),
          amount: safeDouble(row['f6']),
          upCount: safeDouble(row['f104'])?.toInt(),
          downCount: safeDouble(row['f105'])?.toInt(),
          leader: '${row['f128'] ?? ''}'.trim(),
          leaderSymbol: '${row['f140'] ?? ''}'.trim(),
          leaderPct: safeDouble(row['f136']),
        ),
  ];
}

/// clist 成分股响应 → SectorConstituent 列表（f20 总市值是元，统一成亿元）
List<SectorConstituent> parseSectorConstituents(Map<String, dynamic> payload) {
  return [
    for (final row in _diffRows(payload))
      if ('${row['f12'] ?? ''}'.trim().isNotEmpty)
        SectorConstituent(
          symbol: '${row['f12']}'.trim(),
          name: '${row['f14'] ?? ''}'.trim(),
          price: safeDouble(row['f2']),
          pctChg: safeDouble(row['f3']),
          amount: safeDouble(row['f6']),
          marketCap: marketCapYi(safeDouble(row['f20'])),
        ),
  ];
}

/// slist 个股所属板块响应 → 板块引用列表。f13=90 才是板块行
/// （spt=1 会把个股自己也带回来，统一按 f13 过滤更稳）。
List<StockBoardRef> parseStockBoards(Map<String, dynamic> payload) {
  return [
    for (final row in _diffRows(payload))
      if ('${row['f12'] ?? ''}'.trim().isNotEmpty &&
          (safeDouble(row['f13'])?.toInt() ?? 90) == 90)
        StockBoardRef(
          code: '${row['f12']}'.trim(),
          name: '${row['f14'] ?? ''}'.trim(),
          pctChg: safeDouble(row['f3']),
        ),
  ];
}

/// stock/get 响应 → 所属行业名（f127）
String parseStockIndustry(Map<String, dynamic> payload) {
  final data = payload['data'];
  if (data is! Map) return '';
  final industry = '${data['f127'] ?? ''}'.trim();
  return industry == '-' ? '' : industry;
}

/// data.diff 兼容两种形态：数组（常见）与以序号为 key 的对象
List<Map<String, dynamic>> _diffRows(Map<String, dynamic> payload) {
  final data = payload['data'];
  if (data is! Map) return const [];
  final diff = data['diff'];
  final rows = diff is List
      ? diff
      : diff is Map
          ? diff.values.toList()
          : const [];
  return [
    for (final row in rows)
      if (row is Map) row.cast<String, dynamic>(),
  ];
}

class EastmoneySectorProvider {
  static const source = 'eastmoney';

  /// push2 在部分网络下 TLS 不通（且 clist 会 302 到 push2delay），两个域名互为主备
  static const _hosts = [
    'https://push2.eastmoney.com',
    'https://push2delay.eastmoney.com',
  ];

  final Dio _dio;

  EastmoneySectorProvider([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 12),
              headers: {'User-Agent': 'Mozilla/5.0'},
            ));

  /// 板块排行单页（涨幅降序）。page 从 1 开始。
  Future<List<SectorBoard>> boardsPage(String kind, int page,
      {int pageSize = sectorPageSize}) async {
    final payload = await _getJson('/api/qt/clist/get', {
      'pn': '$page',
      'pz': '${pageSize > sectorPageSize ? sectorPageSize : pageSize}',
      'po': '1',
      'np': '1',
      'fltt': '2',
      'invt': '2',
      'fid': 'f3',
      'fs': sectorFs(kind),
      'fields': 'f12,f14,f3,f6,f104,f105,f128,f136,f140',
    });
    return parseSectorBoards(payload, kind);
  }

  /// 板块排行（涨幅降序，limit>100 时自动翻页）
  Future<List<SectorBoard>> boards(String kind, {int limit = 60}) async {
    final all = <SectorBoard>[];
    final seen = <String>{};
    for (var page = 1; page <= 12; page++) {
      final rows = await boardsPage(kind, page);
      if (rows.isEmpty) break;
      for (final row in rows) {
        if (seen.add(row.code)) all.add(row);
      }
      if (all.length >= limit || rows.length < sectorPageSize) break;
    }
    return all.length > limit ? all.sublist(0, limit) : all;
  }

  /// 板块成分股（涨幅降序）
  Future<List<SectorConstituent>> constituents(String code,
      {int limit = 60}) async {
    final payload = await _getJson('/api/qt/clist/get', {
      'pn': '1',
      'pz': '${limit > sectorPageSize ? sectorPageSize : limit}',
      'po': '1',
      'np': '1',
      'fltt': '2',
      'invt': '2',
      'fid': 'f3',
      'fs': 'b:$code',
      'fields': 'f12,f14,f2,f3,f6,f20',
    });
    return parseSectorConstituents(payload);
  }

  /// 个股所属板块（行业/概念/地域混在一起，由上层用概念全集过滤）。
  /// fields 必须带 f4、pn 必须从 1 开始，否则服务端返回空 data。
  Future<List<StockBoardRef>> stockBoards(String symbol) async {
    final payload = await _getJson('/api/qt/slist/get', {
      'spt': '3',
      'fltt': '2',
      'invt': '2',
      'fields': 'f12,f13,f14,f3,f4',
      'secid': _secid(symbol),
      'pn': '1',
      'np': '1',
      'pz': '100',
    });
    return parseStockBoards(payload);
  }

  /// 个股所属行业名（f127），如"白酒Ⅱ"。取不到返回空串。
  Future<String> stockIndustry(String symbol) async {
    final payload = await _getJson('/api/qt/stock/get', {
      'secid': _secid(symbol),
      'fltt': '2',
      'invt': '2',
      'fields': 'f57,f58,f127,f128',
    });
    return parseStockIndustry(payload);
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

  Future<Map<String, dynamic>> _getJson(
      String path, Map<String, String> params) async {
    ProviderError? lastError;
    for (final host in _hosts) {
      try {
        final Response<Map<String, dynamic>> response;
        try {
          response = await _dio.get<Map<String, dynamic>>('$host$path',
              queryParameters: params);
        } on DioException catch (exc) {
          throw ProviderError(exc.message ?? exc.toString(), source);
        }
        if (response.statusCode != 200) {
          throw ProviderError('HTTP ${response.statusCode}', source);
        }
        return response.data ?? const {};
      } on ProviderError catch (exc) {
        lastError = exc;
      }
    }
    throw lastError ?? const ProviderError('no host available', source);
  }
}
