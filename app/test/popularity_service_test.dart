/// 人气榜解析与缓存的单测（用实测响应结构做假数据）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:lazyperson/data/popularity_service.dart';

void main() {
  group('parseRank', () {
    test('解析东财人气榜响应，去掉市场前缀并按排名升序', () {
      final rows = parseRank({
        'data': [
          {'sc': 'SZ300308', 'rk': 3, 'rc': 6},
          {'sc': 'SZ002428', 'rk': 1, 'rc': 2},
          {'sc': 'SH688825', 'rk': 2, 'rc': -1},
        ],
      });
      expect(rows.map((row) => row.symbol), ['002428', '688825', '300308']);
      expect(rows.first.rank, 1);
      expect(rows.first.rankChange, 2);
      expect(rows[1].rankChange, -1);
    });

    test('脏数据/非6位代码跳过，空响应返回空列表', () {
      expect(parseRank({'data': []}), isEmpty);
      expect(parseRank({}), isEmpty);
      final rows = parseRank({
        'data': [
          {'sc': 'BJ43', 'rk': 1},
          'not-a-map',
          {'sc': 'SZ002428', 'rk': 2},
        ],
      });
      expect(rows.map((row) => row.symbol), ['002428']);
    });
  });

  group('PopularStock 序列化', () {
    test('往返保持字段；旧数据缺字段用默认值', () {
      const row = PopularStock(
        symbol: '002428',
        rank: 1,
        name: '云南锗业',
        rankChange: 2,
        price: 100.08,
        pctChg: 10.0,
        industry: 'C32有色金属压延',
        concepts: ['先进封装', '连板'],
      );
      final back = PopularStock.fromJson(
          row.toJson().cast<String, Object?>());
      expect(back.symbol, '002428');
      expect(back.rank, 1);
      expect(back.pctChg, 10.0);
      expect(back.concepts, ['先进封装', '连板']);

      final sparse = PopularStock.fromJson({'symbol': '600519'});
      expect(sparse.name, '');
      expect(sparse.rank, 0);
      expect(sparse.price, isNull);
      expect(sparse.concepts, isEmpty);
    });
  });
}
