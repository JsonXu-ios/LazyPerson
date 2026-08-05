/// 东财板块 provider 的解析单测。假数据是 2026-08 实测响应原样落盘
/// （test/fixtures/sector_*.json），字段名以实测为准。
///
/// 盯住两个实测踩到的坑：
/// - slist 的 fields 必须带 f4，且 pn 从 1 开始，否则服务端返回空 data；
/// - clist 单页最多 100 行，pz 写更大也没用，要靠翻页。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/providers/eastmoney_sector_provider.dart';

import 'fixtures_util.dart';

Map<String, dynamic> _fixture(String name) =>
    (loadFixture(name) as Map).cast<String, dynamic>();

/// 按 URL 关键字返回预置响应，并记录请求过的 URL
class _FakeAdapter implements HttpClientAdapter {
  final Map<String, String> bodies;
  final List<String> requestedUrls = [];

  _FakeAdapter(this.bodies);

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
            Headers.contentTypeHeader: ['application/json'],
          },
        );
      }
    }
    return ResponseBody.fromString('{}', 200, headers: {
      Headers.contentTypeHeader: ['application/json'],
    });
  }

  @override
  void close({bool force = false}) {}
}

EastmoneySectorProvider _provider(_FakeAdapter adapter) {
  final dio = Dio(BaseOptions(headers: {'User-Agent': 'Mozilla/5.0'}));
  dio.httpClientAdapter = adapter;
  return EastmoneySectorProvider(dio);
}

void main() {
  group('板块排行解析', () {
    test('行业榜 m:90+t:2：代码/名称/涨幅/成交额/涨跌家数/领涨股', () {
      final rows = parseSectorBoards(
          _fixture('sector_boards_industry.json'), sectorKindIndustry);
      expect(rows, hasLength(3));
      final first = rows.first;
      expect(first.code, 'BK1625');
      expect(first.name, '钨');
      expect(first.kind, sectorKindIndustry);
      expect(first.pctChg, 8.97);
      expect(first.amount, 12991395069.0);
      expect(first.upCount, 4);
      expect(first.downCount, 0);
      expect(first.leader, '翔鹭钨业');
      expect(first.leaderSymbol, '002842');
      expect(first.leaderPct, 9.99);
      // 服务端 fid=f3 已按涨幅降序，解析不再重排
      expect(rows.map((row) => row.pctChg), [8.97, 8.4, 8.1]);
    });

    test('概念榜 m:90+t:3：同一套字段，kind 标成 concept', () {
      final rows = parseSectorBoards(
          _fixture('sector_boards_concept.json'), sectorKindConcept);
      expect(rows.map((row) => row.name),
          ['高带宽内存', 'MLCC', '中芯概念']);
      expect(rows.every((row) => row.kind == sectorKindConcept), isTrue);
      expect(rows.first.leaderPct, 20.01);
    });

    test('fs 参数：行业 t:2 / 概念 t:3', () {
      expect(sectorFs(sectorKindIndustry), 'm:90+t:2');
      expect(sectorFs(sectorKindConcept), 'm:90+t:3');
    });

    test('空 data / 缺 diff → 空列表，不抛', () {
      expect(parseSectorBoards(const {}, sectorKindConcept), isEmpty);
      expect(
          parseSectorBoards(
              const {'data': null}, sectorKindConcept),
          isEmpty);
      expect(
          parseSectorBoards(
              const {'data': <String, dynamic>{}}, sectorKindConcept),
          isEmpty);
    });
  });

  group('成分股解析', () {
    test('fs=b:{code}：代码/名称/现价/涨幅/成交额，总市值元→亿元', () {
      final rows =
          parseSectorConstituents(_fixture('sector_constituents_BK1625.json'));
      expect(rows, hasLength(4));
      final first = rows.first;
      expect(first.symbol, '000657');
      expect(first.name, '中钨高新');
      expect(first.price, 57.43);
      expect(first.pctChg, 10.0);
      expect(first.amount, 4578036475.01);
      // f20 是元，统一成亿元
      expect(first.marketCap, closeTo(1308.6, 0.1));
    });
  });

  group('个股所属板块解析（slist spt=3）', () {
    test('实测响应：贵州茅台 29 个所属板块，行业/概念/地域混在一起', () {
      final rows = parseStockBoards(_fixture('sector_slist_600519.json'));
      expect(rows, hasLength(29));
      expect(rows.first.code, 'BK0438');
      expect(rows.first.name, '食品饮料');
      final names = rows.map((row) => row.name).toList();
      // 行业（白酒Ⅱ）、地域（贵州板块）、概念（酿酒概念）都在同一份返回里，
      // 由 SectorService 用概念板块全集过滤
      expect(names, containsAll(['白酒Ⅱ', '贵州板块', '酿酒概念']));
    });

    test('f13 != 90 的行（spt=1 会带回个股自己）被过滤掉', () {
      final rows = parseStockBoards(const {
        'data': {
          'diff': [
            {'f12': '600519', 'f13': 1, 'f14': '贵州茅台', 'f3': -1.61},
            {'f12': 'BK1277', 'f13': 90, 'f14': '白酒Ⅱ', 'f3': -0.81},
          ],
        },
      });
      expect(rows, hasLength(1));
      expect(rows.single.code, 'BK1277');
      expect(rows.single.pctChg, -0.81);
    });
  });

  group('个股行业（stock/get f127）', () {
    test('实测响应：600519 → 白酒Ⅱ', () {
      expect(parseStockIndustry(_fixture('sector_stock_get_600519.json')),
          '白酒Ⅱ');
    });

    test('缺字段 / 占位「-」→ 空串', () {
      expect(parseStockIndustry(const {}), '');
      expect(parseStockIndustry(const {'data': {'f127': '-'}}), '');
    });
  });

  group('请求参数（实测踩到的坑）', () {
    test('slist 必须带 f4 且 pn=1，否则服务端返回空 data', () async {
      final adapter = _FakeAdapter({
        '/api/qt/slist/get':
            jsonEncode(loadFixture('sector_slist_600519.json')),
      });
      final rows = await _provider(adapter).stockBoards('600519');
      expect(rows, hasLength(29));
      final url = adapter.requestedUrls.single;
      expect(url, contains('spt=3'));
      expect(url, contains('secid=1.600519')); // 6 开头走沪市 1.
      expect(url, contains('pn=1'));
      expect(Uri.parse(url).queryParameters['fields']!.split(','),
          contains('f4'));
    });

    test('深市个股 secid 前缀是 0.', () async {
      final adapter = _FakeAdapter({
        '/api/qt/slist/get':
            jsonEncode(loadFixture('sector_slist_600519.json')),
      });
      await _provider(adapter).stockBoards('000001');
      expect(adapter.requestedUrls.single, contains('secid=0.000001'));
    });

    test('板块排行请求带 fid=f3（涨幅降序）与对应 fs', () async {
      final adapter = _FakeAdapter({
        '/api/qt/clist/get':
            jsonEncode(loadFixture('sector_boards_concept.json')),
      });
      await _provider(adapter).boardsPage(sectorKindConcept, 1);
      final params = Uri.parse(adapter.requestedUrls.single).queryParameters;
      expect(params['fid'], 'f3');
      expect(params['fs'], 'm:90+t:3');
      expect(params['pn'], '1');
    });

    test('单页最多 100 行：pz 请求超过 100 时压回 100', () async {
      final adapter = _FakeAdapter({
        '/api/qt/clist/get':
            jsonEncode(loadFixture('sector_constituents_BK1625.json')),
      });
      await _provider(adapter).constituents('BK1625', limit: 500);
      expect(Uri.parse(adapter.requestedUrls.single).queryParameters['pz'],
          '$sectorPageSize');
    });

    test('翻页：返回不足一页就停，limit 内去重截断', () async {
      // 固定 3 行的响应（不足 100）→ 只请求一页
      final adapter = _FakeAdapter({
        '/api/qt/clist/get':
            jsonEncode(loadFixture('sector_boards_concept.json')),
      });
      final rows = await _provider(adapter).boards(sectorKindConcept, limit: 50);
      expect(rows, hasLength(3));
      expect(adapter.requestedUrls, hasLength(1));
    });

    test('主域名失败自动切备用域名', () async {
      var calls = 0;
      final dio = Dio();
      dio.httpClientAdapter = _FlakyAdapter(
        onFetch: (url) {
          calls += 1;
          if (url.contains('//push2.eastmoney.com')) throw StateError('tls');
          return jsonEncode(loadFixture('sector_boards_concept.json'));
        },
      );
      final rows =
          await EastmoneySectorProvider(dio).boardsPage(sectorKindConcept, 1);
      expect(calls, 2); // push2 失败 → push2delay 成功
      expect(rows, hasLength(3));
    });
  });
}

/// 按 URL 决定成功/抛错的适配器，用来测主备域名切换
class _FlakyAdapter implements HttpClientAdapter {
  final String Function(String url) onFetch;

  _FlakyAdapter({required this.onFetch});

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final url = options.uri.toString();
    try {
      final body = onFetch(url);
      return ResponseBody.fromString(body, 200, headers: {
        Headers.contentTypeHeader: ['application/json'],
      });
    } on StateError catch (exc) {
      throw DioException(requestOptions: options, message: exc.message);
    }
  }

  @override
  void close({bool force = false}) {}
}
