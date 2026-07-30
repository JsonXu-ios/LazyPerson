/// 东财财务 provider 的解析单测。
/// 重点盯住一个坑：datacenter 的 Content-Type 是 text/plain，
/// Dio 默认只对 application/json 反序列化，所以 provider 必须自己 jsonDecode。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/provider_error.dart';
import 'package:lazyperson/data/providers/eastmoney_fundamentals_provider.dart';

/// 按 URL 里的 reportName / 路径返回预置响应，并可指定 Content-Type
class _FakeAdapter implements HttpClientAdapter {
  final Map<String, String> bodies;
  final String contentType;
  final List<String> requestedUrls = [];

  _FakeAdapter(this.bodies, {this.contentType = 'text/plain;charset=UTF-8'});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    requestedUrls.add(url);
    for (final entry in bodies.entries) {
      if (url.contains(entry.key)) {
        return ResponseBody.fromString(
          entry.value,
          200,
          headers: {
            Headers.contentTypeHeader: [contentType],
          },
        );
      }
    }
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: [contentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

String _report(List<Map<String, Object?>> rows) =>
    jsonEncode({'result': {'data': rows}, 'success': true});

final _performanceRow = {
  'SECURITY_CODE': '600519',
  'SECURITY_NAME_ABBR': '贵州茅台',
  'REPORTDATE': '2025-12-31 00:00:00',
  'NOTICE_DATE': '2026-04-17 00:00:00',
  'DATATYPE': '2025年 年报',
  'BASIC_EPS': 65.66,
  'TOTAL_OPERATE_INCOME': 172054171890.91,
  'YSTZ': -1.2000971769,
  'PARENT_NETPROFIT': 82320067101.68,
  'SJLTZ': -4.53,
  'WEIGHTAVG_ROE': 32.53,
  'BPS': 195.355449727901,
};

final _incomeRow = {
  'REPORT_DATE': '2025-12-31 00:00:00',
  'TOTAL_PROFIT': 114755261605.08,
  'INCOME_TAX': 29444936771.41,
  'DEDUCT_PARENT_NETPROFIT': 82293107655.25,
};

final _bonusRow = {
  'REPORT_DATE': '2025-12-31 00:00:00',
  'IMPL_PLAN_PROFILE': '10派280.2423元(含税)',
  'ASSIGN_PROGRESS': '实施分配',
  'PRETAX_BONUS_RMB': 280.2423,
  'DIVIDENT_RATIO': 0.023120394357,
  'EX_DIVIDEND_DATE': '2026-06-26 00:00:00',
};

const _valuationBody =
    '{"data":{"total":1,"diff":[{"f2":1361.76,"f9":15.62,"f12":"600519",'
    '"f14":"贵州茅台","f20":1702311120978,"f21":1702311120978,"f23":7.22,"f115":20.58}]}}';

EastmoneyFundamentalsProvider _providerWith(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(headers: {'User-Agent': 'test'}));
  dio.httpClientAdapter = adapter;
  return EastmoneyFundamentalsProvider(dio);
}

void main() {
  final bodies = {
    'RPT_LICO_FN_CPD': _report([_performanceRow]),
    'RPT_DMSK_FN_INCOME': _report([_incomeRow]),
    'RPT_SHAREBONUS_DET': _report([_bonusRow]),
    'ulist.np': _valuationBody,
  };

  group('datacenter 的 text/plain 响应', () {
    test('前提：Dio 默认不把 text/plain 解成 Map（本组测试存在的理由）', () async {
      // 这条锁住的是 Dio 的行为本身：content-type 不是 JSON 时它原样返回字符串，
      // 于是 get<Map<String, dynamic>> 会炸。provider 里手动 jsonDecode 就是为了绕开它。
      final dio = Dio();
      dio.httpClientAdapter = _FakeAdapter({'probe': '{"a":1}'});

      await expectLater(
        dio.get<Map<String, dynamic>>('https://example.com/probe'),
        throwsA(anything),
      );
    });

    test('按纯文本收再 jsonDecode，不依赖服务端 content-type', () async {
      // 真实接口返回的就是 text/plain，Dio 默认不会解成 Map
      final provider = _providerWith(_FakeAdapter(bodies));

      final data = await provider.fundamentals('600519');

      expect(data.symbol, '600519');
      expect(data.name, '贵州茅台');
      expect(data.reports, hasLength(1));
      expect(data.dividends, hasLength(1));
      expect(data.warnings, isEmpty);
    });

    test('content-type 换成 application/json 也照样解', () async {
      final provider = _providerWith(
          _FakeAdapter(bodies, contentType: 'application/json; charset=UTF-8'));

      final data = await provider.fundamentals('600519');

      expect(data.reports, hasLength(1));
    });
  });

  group('字段映射', () {
    test('业绩 + 利润表合并，净利润由 利润总额-所得税 推出', () async {
      final provider = _providerWith(_FakeAdapter(bodies));

      final report = (await provider.fundamentals('600519')).latestReport!;

      expect(report.reportDate, '2025-12-31');
      expect(report.reportType, '2025年 年报');
      expect(report.eps, 65.66);
      expect(report.parentNetprofit, 82320067101.68);
      expect(report.parentNetprofitYoy, -4.53);
      expect(report.roe, 32.53);
      expect(report.deductParentNetprofit, 82293107655.25);
      expect(report.netprofit, closeTo(85310324833.67, 0.01));
    });

    test('利润表缺该报告期时净利润留空，不拿归母硬凑', () async {
      final provider = _providerWith(_FakeAdapter({
        ...bodies,
        'RPT_DMSK_FN_INCOME': _report([
          {..._incomeRow, 'REPORT_DATE': '2024-12-31 00:00:00'},
        ]),
      }));

      final report = (await provider.fundamentals('600519')).latestReport!;

      expect(report.netprofit, isNull);
      expect(report.deductParentNetprofit, isNull);
    });

    test('分红字段与股息率', () async {
      final provider = _providerWith(_FakeAdapter(bodies));

      final dividend = (await provider.fundamentals('600519')).dividends.first;

      expect(dividend.plan, '10派280.2423元(含税)');
      expect(dividend.progress, '实施分配');
      expect(dividend.pretaxBonus, 280.2423);
      expect(dividend.exDividendDate, '2026-06-26');
    });

    test('估值走 push2 的 diff 数组', () async {
      final provider = _providerWith(_FakeAdapter(bodies));

      final valuation = (await provider.fundamentals('600519')).valuation;

      expect(valuation.pe, 15.62);
      expect(valuation.peTtm, 20.58);
      expect(valuation.pb, 7.22);
      expect(valuation.marketCap, 1702311120978.0);
    });
  });

  group('降级', () {
    test('估值挂了只记 warning，财务部分照常返回', () async {
      final provider = _providerWith(_FakeAdapter({
        'RPT_LICO_FN_CPD': _report([_performanceRow]),
        'RPT_DMSK_FN_INCOME': _report([_incomeRow]),
        'RPT_SHAREBONUS_DET': _report([_bonusRow]),
        'ulist.np': 'not json at all',
      }));

      final data = await provider.fundamentals('600519');

      expect(data.reports, hasLength(1));
      expect(data.valuation.pe, isNull);
      expect(data.warnings.single, startsWith('valuation:'));
    });

    test('业绩与分红都为空时抛 ProviderError', () async {
      final provider = _providerWith(_FakeAdapter({
        'RPT_LICO_FN_CPD': _report([]),
        'RPT_DMSK_FN_INCOME': _report([]),
        'RPT_SHAREBONUS_DET': _report([]),
        'ulist.np': _valuationBody,
      }));

      expect(() => provider.fundamentals('600519'),
          throwsA(isA<ProviderError>()));
    });
  });
}
