/// 人气股：东方财富人气榜 TOP100，补上名称/现价/涨跌与所属行业、概念。
///
/// 榜单接口只返回代码与排名（sc/rk/rc），行情走腾讯批量（app 已有），
/// 行业/概念复用 [SectorService] 的按天缓存，不额外增加取数成本。
/// 结果缓存 5 分钟，与网页版 backend/app/popularity.py 口径一致。
library;

import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/models.dart';
import 'local_store.dart';
import 'providers/tencent_provider.dart';
import 'sector_service.dart';

const popularityRankUrl =
    'https://emappdata.eastmoney.com/stockrank/getAllCurrentList';
const popularityCacheKey = 'popularity:rank:v1';
const popularityTtl = Duration(minutes: 5);

/// 人气榜一行：排名 + 行情 + 板块
class PopularStock {
  final String symbol;
  final String name;
  final int rank;

  /// 较上次的排名变化（正 = 名次上升）
  final double? rankChange;
  final double? price;
  final double? pctChg;
  final double? turnover;
  final String industry;
  final List<String> concepts;

  const PopularStock({
    required this.symbol,
    required this.rank,
    this.name = '',
    this.rankChange,
    this.price,
    this.pctChg,
    this.turnover,
    this.industry = '',
    this.concepts = const [],
  });

  Map<String, Object?> toJson() => {
        'symbol': symbol,
        'name': name,
        'rank': rank,
        'rank_change': rankChange,
        'price': price,
        'pct_chg': pctChg,
        'turnover': turnover,
        'industry': industry,
        'concepts': concepts,
      };

  factory PopularStock.fromJson(Map<String, Object?> json) => PopularStock(
        symbol: json['symbol'] as String,
        name: (json['name'] as String?) ?? '',
        rank: (json['rank'] as num?)?.toInt() ?? 0,
        rankChange: (json['rank_change'] as num?)?.toDouble(),
        price: (json['price'] as num?)?.toDouble(),
        pctChg: (json['pct_chg'] as num?)?.toDouble(),
        turnover: (json['turnover'] as num?)?.toDouble(),
        industry: (json['industry'] as String?) ?? '',
        concepts: [
          for (final item in (json['concepts'] as List? ?? const [])) '$item',
        ],
      );
}

/// 解析东财人气榜响应（纯函数，便于测试）
List<({String symbol, int rank, double? rankChange})> parseRank(
    Map<String, Object?> payload) {
  final rows = payload['data'] as List? ?? const [];
  final result = <({String symbol, int rank, double? rankChange})>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final raw = '${row['sc'] ?? ''}';
    // sc 形如 SZ002428 / SH688825，去掉市场前缀
    final symbol = raw.length > 2 && RegExp(r'^[A-Za-z]{2}').hasMatch(raw)
        ? raw.substring(2)
        : raw;
    if (!RegExp(r'^\d{6}$').hasMatch(symbol)) continue;
    result.add((
      symbol: symbol,
      rank: (row['rk'] as num?)?.toInt() ?? 0,
      rankChange: (row['rc'] as num?)?.toDouble(),
    ));
  }
  result.sort((a, b) => a.rank.compareTo(b.rank));
  return result;
}

class PopularityService {
  final LocalStore store;
  final TencentProvider tencent;
  final SectorService sectors;
  final Dio dio;

  PopularityService({
    required this.store,
    required this.sectors,
    TencentProvider? tencent,
    Dio? dio,
  })  : tencent = tencent ?? TencentProvider(),
        dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 12),
              responseType: ResponseType.plain,
            ));

  /// TOP N 人气股（默认走 5 分钟缓存；[refresh] 强制重取，失败回落过期缓存）
  Future<List<PopularStock>> topStocks({
    int limit = 100,
    bool refresh = false,
  }) async {
    if (!refresh) {
      final cached = await store.readFrame(popularityCacheKey);
      if (cached != null && !cached.stale) {
        return _decode(cached.payloadJson).take(limit).toList();
      }
    }
    try {
      final rows = await _fetch(limit);
      await store.writeFrame(
        cacheKey: popularityCacheKey,
        dataType: 'popularity',
        payloadJson: jsonEncode([for (final row in rows) row.toJson()]),
        source: 'eastmoney',
        ttl: popularityTtl,
      );
      return rows;
    } catch (_) {
      // 取数失败：有过期缓存就先用着，没有就空列表（界面提示）
      final cached = await store.readFrame(popularityCacheKey, allowStale: true);
      if (cached != null) return _decode(cached.payloadJson).take(limit).toList();
      rethrow;
    }
  }

  List<PopularStock> _decode(String payloadJson) => [
        for (final row in jsonDecode(payloadJson) as List)
          PopularStock.fromJson((row as Map).cast<String, Object?>()),
      ];

  Future<List<PopularStock>> _fetch(int limit) async {
    final ranks = await _fetchRank(limit);
    if (ranks.isEmpty) throw StateError('人气榜返回为空');

    final symbols = [for (final row in ranks) row.symbol];
    final quotes = <String, Quote>{};
    for (var start = 0; start < symbols.length; start += 80) {
      final batch = symbols.sublist(
          start, start + 80 > symbols.length ? symbols.length : start + 80);
      try {
        for (final quote in await tencent.realtimeQuotes(batch)) {
          quotes[quote.symbol] = quote;
        }
      } catch (_) {
        // 单批行情失败不影响榜单本身
      }
    }

    // 行业/概念：批量取一次（按天缓存），列表渲染时零请求
    var stockSectors = <String, StockSectors>{};
    try {
      stockSectors = await sectors.sectorsOfMany(symbols);
    } catch (_) {
      // 板块拿不到就先不显示
    }

    return [
      for (final row in ranks)
        PopularStock(
          symbol: row.symbol,
          rank: row.rank,
          rankChange: row.rankChange,
          name: quotes[row.symbol]?.name ?? '',
          price: quotes[row.symbol]?.price,
          pctChg: quotes[row.symbol]?.pctChg,
          turnover: quotes[row.symbol]?.turnover,
          industry: stockSectors[row.symbol]?.industry ?? '',
          concepts: stockSectors[row.symbol]?.concepts.take(4).toList() ?? const [],
        ),
    ];
  }

  /// 榜单接口偶发超时，重试几次再放弃（对齐后端 fetch_rank）
  Future<List<({String symbol, int rank, double? rankChange})>> _fetchRank(
    int limit, {
    int attempts = 3,
  }) async {
    Object? lastError;
    for (var attempt = 0; attempt < attempts; attempt++) {
      try {
        final response = await dio.post<String>(
          popularityRankUrl,
          data: jsonEncode({
            'appId': 'appId01',
            'globalId': '786e4c21-70dc-435a-93bb-38',
            'marketType': '',
            'pageNo': 1,
            'pageSize': limit.clamp(1, 100),
          }),
          options: Options(headers: const {'Content-Type': 'application/json'}),
        );
        final rows = parseRank(
            (jsonDecode(response.data ?? '{}') as Map).cast<String, Object?>());
        if (rows.isNotEmpty) return rows.take(limit).toList();
        lastError = StateError('empty');
      } catch (exc) {
        lastError = exc;
      }
      if (attempt < attempts - 1) {
        await Future<void>.delayed(Duration(milliseconds: 600 * (attempt + 1)));
      }
    }
    throw StateError('人气榜取数失败：$lastError');
  }
}
