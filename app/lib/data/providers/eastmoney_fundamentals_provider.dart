/// 东方财富财务数据源，字段与流程逐条对齐 backend/app/providers/eastmoney_adapter.py。
/// - datacenter-web RPT_LICO_FN_CPD    业绩报表（EPS/营收/归母净利润/ROE/毛利率/同比）
/// - datacenter-web RPT_DMSK_FN_INCOME 利润表（利润总额/所得税/扣非归母 → 推出净利润）
/// - datacenter-web RPT_SHAREBONUS_DET 分红送配（方案/股息率/除权除息日）
/// - push2 ulist.np                    估值（PE/PE-TTM/PB/总市值/流通市值）
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../../models/models.dart';
import '../provider_error.dart';
import '../symbol_utils.dart';

class EastmoneyFundamentalsProvider {
  static const source = 'eastmoney';

  static const _datacenterUrl =
      'https://datacenter-web.eastmoney.com/api/data/v1/get';

  /// push2 在部分网络下 TLS 不通，push2delay 提供同一接口
  static const _quoteHosts = [
    'https://push2.eastmoney.com',
    'https://push2delay.eastmoney.com',
  ];

  /// 最近 8 期报告（约两年）
  static const maxReports = 8;
  static const maxDividends = 8;

  static const _headers = {
    'User-Agent': 'Mozilla/5.0',
    'Referer': 'https://data.eastmoney.com/',
  };

  final Dio _dio;

  /// 估值专用：主域名 push2 在部分网络下连不上，连接超时也压短，
  /// 好让 push2delay 尽快接手（BaseOptions 的 connectTimeout 无法按请求覆盖）
  final Dio _quoteDio;

  EastmoneyFundamentalsProvider([Dio? dio])
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 15),
              receiveTimeout: const Duration(seconds: 15),
              headers: _headers,
            )),
        _quoteDio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 6),
              receiveTimeout: const Duration(seconds: 6),
              headers: _headers,
            ));

  /// datacenter 的 Content-Type 是 text/plain，Dio 默认只对 application/json
  /// 反序列化，所以统一按纯文本收再自己 jsonDecode，不依赖服务端的 content-type。
  Future<Map<String, dynamic>> _getJson(
    Dio dio,
    String url,
    Map<String, String> params,
  ) async {
    final Response<String> response;
    try {
      response = await dio.get<String>(
        url,
        queryParameters: params,
        options: Options(responseType: ResponseType.plain),
      );
    } on DioException catch (exc) {
      throw ProviderError(exc.message ?? exc.toString(), source);
    }
    if (response.statusCode != 200) {
      throw ProviderError('HTTP ${response.statusCode}', source);
    }
    final body = response.data;
    if (body == null || body.isEmpty) return const {};
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException catch (exc) {
      throw ProviderError('invalid json: ${exc.message}', source);
    }
  }

  Future<List<Map<String, dynamic>>> _reportRows(
    String reportName,
    String symbol,
    String sortColumn,
    int pageSize, {
    String extraFilter = '',
  }) async {
    final payload = await _getJson(_dio, _datacenterUrl, {
      'reportName': reportName,
      'columns': 'ALL',
      'filter': '(SECURITY_CODE="$symbol")$extraFilter',
      'pageNumber': '1',
      'pageSize': '$pageSize',
      'sortColumns': sortColumn,
      'sortTypes': '-1',
      'source': 'WEB',
      'client': 'WEB',
    });
    final result = payload['result'];
    if (result is! Map) return const [];
    final data = result['data'];
    if (data is! List) return const [];
    return [
      for (final row in data)
        if (row is Map<String, dynamic>) row,
    ];
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

  /// PE(动)/PE(TTM)/PB/总市值/流通市值。主域名超时较短，尽快降级到备用域名。
  Future<FundamentalValuation> valuation(String symbol) async {
    final params = {
      'secids': _secid(symbol),
      'fields': 'f12,f14,f2,f9,f23,f20,f21,f115',
      'fltt': '2',
      'invt': '2',
    };
    final errors = <String>[];
    for (final host in _quoteHosts) {
      Map<String, dynamic> payload;
      try {
        payload = await _getJson(
          _quoteDio,
          '$host/api/qt/ulist.np/get',
          params,
        );
      } on ProviderError catch (exc) {
        errors.add('$host:$exc');
        continue;
      }
      final data = payload['data'];
      final diff = data is Map ? data['diff'] : null;
      final rows = diff is List
          ? diff
          : diff is Map
              ? diff.values.toList()
              : const [];
      if (rows.isEmpty || rows.first is! Map) {
        errors.add('$host:empty');
        continue;
      }
      final row = (rows.first as Map).cast<String, Object?>();
      return FundamentalValuation(
        price: safeDouble(row['f2']),
        pe: safeDouble(row['f9']),
        peTtm: safeDouble(row['f115']),
        pb: safeDouble(row['f23']),
        marketCap: safeDouble(row['f20']),
        floatMarketCap: safeDouble(row['f21']),
      );
    }
    throw ProviderError(
        errors.isEmpty ? 'no valuation data' : errors.join('; '), source);
  }

  /// 分红送配记录（八档局基本面标记等轻量场景：单接口，不拉业绩/估值）。
  Future<List<FundamentalDividend>> dividends(String symbol) async {
    final clean = normalizeSymbol(symbol);
    final rows = await _reportRows(
        'RPT_SHAREBONUS_DET', clean, 'PLAN_NOTICE_DATE', maxDividends);
    return [for (final row in rows) _normalizeDividend(row)];
  }

  /// 指定报告期的业绩报表（如今年一季报 '2026-03-31'）；未披露返回 null。
  /// 只查 RPT_LICO_FN_CPD，不合并利润表（netprofit/扣非等留空）。
  Future<FundamentalReport?> reportAt(String symbol, String reportDate) async {
    final clean = normalizeSymbol(symbol);
    final rows = await _reportRows(
      'RPT_LICO_FN_CPD',
      clean,
      'REPORTDATE',
      1,
      extraFilter: "(REPORTDATE='$reportDate')",
    );
    if (rows.isEmpty) return null;
    return _normalizeReport(rows.first, const {});
  }

  /// 业绩 + 分红 + 估值的合并结果。估值失败不影响财务部分，只记 warning。
  Future<Fundamentals> fundamentals(String symbol) async {
    final clean = normalizeSymbol(symbol);
    final performance =
        await _reportRows('RPT_LICO_FN_CPD', clean, 'REPORTDATE', maxReports);
    final income =
        await _reportRows('RPT_DMSK_FN_INCOME', clean, 'REPORT_DATE', maxReports);
    final bonus = await _reportRows(
        'RPT_SHAREBONUS_DET', clean, 'PLAN_NOTICE_DATE', maxDividends);
    if (performance.isEmpty && bonus.isEmpty) {
      throw const ProviderError('no fundamentals data', source);
    }

    final warnings = <String>[];
    FundamentalValuation? valuationData;
    try {
      valuationData = await valuation(clean);
    } on ProviderError catch (exc) {
      warnings.add('valuation:$exc');
    }

    final incomeByDate = <String, Map<String, dynamic>>{
      for (final row in income) _dateOnly(row['REPORT_DATE']): row,
    };
    var name = '';
    for (final row in [...performance, ...bonus]) {
      name = '${row['SECURITY_NAME_ABBR'] ?? ''}'.trim();
      if (name.isNotEmpty) break;
    }

    return Fundamentals(
      symbol: clean,
      name: name,
      valuation: valuationData ?? const FundamentalValuation(),
      reports: [
        for (final row in performance) _normalizeReport(row, incomeByDate),
      ],
      dividends: [for (final row in bonus) _normalizeDividend(row)],
      warnings: warnings,
    );
  }
}

String _dateOnly(Object? value) {
  final text = '${value ?? ''}';
  return text.length >= 10 ? text.substring(0, 10) : text;
}

FundamentalReport _normalizeReport(
  Map<String, dynamic> row,
  Map<String, Map<String, dynamic>> incomeByDate,
) {
  final reportDate = _dateOnly(row['REPORTDATE']);
  final income = incomeByDate[reportDate] ?? const <String, dynamic>{};
  final totalProfit = safeDouble(income['TOTAL_PROFIT']);
  final incomeTax = safeDouble(income['INCOME_TAX']);
  // 业绩报表只给归母净利润；净利润（含少数股东）用利润表的 利润总额-所得税 推出
  final netprofit = totalProfit != null && incomeTax != null
      ? totalProfit - incomeTax
      : null;
  return FundamentalReport(
    reportDate: reportDate,
    reportType: '${row['DATATYPE'] ?? ''}'.trim(), // 例："2025年 年报"
    noticeDate: _dateOnly(row['NOTICE_DATE']),
    eps: safeDouble(row['BASIC_EPS']),
    deductEps: safeDouble(row['DEDUCT_BASIC_EPS']),
    bps: safeDouble(row['BPS']),
    revenue: safeDouble(row['TOTAL_OPERATE_INCOME']),
    revenueYoy: safeDouble(row['YSTZ']),
    parentNetprofit: safeDouble(row['PARENT_NETPROFIT']),
    parentNetprofitYoy: safeDouble(row['SJLTZ']),
    deductParentNetprofit: safeDouble(income['DEDUCT_PARENT_NETPROFIT']),
    netprofit: netprofit,
    totalProfit: totalProfit,
    incomeTax: incomeTax,
    roe: safeDouble(row['WEIGHTAVG_ROE']),
    grossMargin: safeDouble(row['XSMLL']),
    operatingCashflowPs: safeDouble(row['MGJYXJJE']),
  );
}

FundamentalDividend _normalizeDividend(Map<String, dynamic> row) {
  return FundamentalDividend(
    reportDate: _dateOnly(row['REPORT_DATE']),
    plan: '${row['IMPL_PLAN_PROFILE'] ?? ''}'.trim(),
    progress: '${row['ASSIGN_PROGRESS'] ?? ''}'.trim(),
    pretaxBonus: safeDouble(row['PRETAX_BONUS_RMB']), // 每 10 股税前派息（元）
    bonusRatio: safeDouble(row['BONUS_RATIO']), // 每 10 股送股
    itRatio: safeDouble(row['IT_RATIO']), // 每 10 股转增
    dividendRatio: safeDouble(row['DIVIDENT_RATIO']), // 股息率（小数）
    planNoticeDate: _dateOnly(row['PLAN_NOTICE_DATE']),
    equityRecordDate: _dateOnly(row['EQUITY_RECORD_DATE']),
    exDividendDate: _dateOnly(row['EX_DIVIDEND_DATE']),
  );
}
