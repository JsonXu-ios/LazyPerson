/// 板块数据服务：今日热点板块（行业/概念）、板块成分股、个股行业与概念。
/// 口径对齐 backend/app/sectors.py + backend/app/industry.py，取数全部走东财
/// （app 在手机网络下东财可达，不需要后端那套同花顺 + 成分股反查的降级）。
///
/// 与后端的两处口径差异，都是因为 app 能直连东财：
/// - 行业榜后端用同花顺（无板块代码、不能展开成分股），app 用东财 m:90+t:2，
///   行业榜也能点开成分股；
/// - 个股概念后端靠"拉前 200 概念板块成分股反查"建映射，app 直接用
///   slist 查个股所属板块（实测可用），再用概念板块全集过滤掉地域/指数成分
///   等噪声板块；行业用 stock/get 的 f127。
///
/// 缓存：热点榜与成分股走 frames 表，TTL 5 分钟；概念板块全集与个股板块
/// 走 app_state，按天失效。
library;

import 'dart:convert';

import '../models/models.dart';
import 'local_store.dart';
import 'providers/eastmoney_sector_provider.dart';

/// 板块类别常量转出给上层（state/ui 不直接依赖 providers/）
export 'providers/eastmoney_sector_provider.dart'
    show sectorKindConcept, sectorKindIndustry;

/// 热点榜/成分股缓存 5 分钟（对齐 backend HOT_TTL_SECONDS = 300）
const sectorHotTtl = Duration(minutes: 5);

/// 概念板块全集缓存 key（按天重建）
const sectorConceptBoardsKey = 'sector:concept_boards:v1';

/// 个股板块缓存 key 前缀（按天重建）
const sectorStatePrefix = 'sector:stock:v1:';

/// 判定"热点"时取概念榜前几名（对齐 backend _default_sector_enricher 的 hot_top=15）
const sectorHotTop = 15;

/// 命中卡/摘要上最多展示几个概念（对齐 backend row["concepts"] = concepts[:6]）
const sectorMaxConcepts = 6;

class SectorService {
  final LocalStore store;
  final EastmoneySectorProvider provider;
  final DateTime Function() now;

  SectorService({
    required this.store,
    EastmoneySectorProvider? provider,
    DateTime Function()? nowFn,
  })  : provider = provider ?? EastmoneySectorProvider(),
        now = nowFn ?? DateTime.now;

  String get _today => now().toIso8601String().substring(0, 10);

  // ---------- 热点板块 ----------

  /// 今日热点板块：行业榜 + 概念榜，各取前 limit 名（涨幅降序）。
  /// 两榜各自独立降级：一边取数失败不影响另一边（对齐 backend hot_boards）。
  Future<HotSectors> hotBoards({int limit = 20, bool refresh = false}) async {
    final industries = await _cachedBoards(sectorKindIndustry, refresh);
    final concepts = await _cachedBoards(sectorKindConcept, refresh);
    return HotSectors(
      industries: _take(industries, limit),
      concepts: _take(concepts, limit),
    );
  }

  /// 板块成分股（涨幅降序），缓存 5 分钟
  Future<List<SectorConstituent>> constituents(String code,
      {int limit = 60, bool refresh = false}) async {
    final cacheKey = 'sector:cons:$code';
    if (!refresh) {
      final cached = await store.readFrame(cacheKey);
      if (cached != null) {
        final rows = _decodeList(cached.payloadJson, SectorConstituent.fromJson);
        if (rows.isNotEmpty) return _take(rows, limit);
      }
    }
    final rows = await provider.constituents(code, limit: limit);
    if (rows.isNotEmpty) {
      await store.writeFrame(
        cacheKey: cacheKey,
        dataType: 'sector',
        payloadJson: jsonEncode([for (final row in rows) row.toJson()]),
        source: EastmoneySectorProvider.source,
        ttl: sectorHotTtl,
      );
    }
    return _take(rows, limit);
  }

  /// 热点榜取数失败时回落到过期缓存（对齐 backend _cached 的 allow_stale）
  Future<List<SectorBoard>> _cachedBoards(String kind, bool refresh) async {
    final cacheKey = 'sector:hot:$kind';
    if (!refresh) {
      final cached = await store.readFrame(cacheKey);
      if (cached != null) {
        final rows = _decodeList(cached.payloadJson, SectorBoard.fromJson);
        if (rows.isNotEmpty) return rows;
      }
    }
    try {
      final rows = await provider.boards(kind, limit: sectorPageSize);
      if (rows.isNotEmpty) {
        await store.writeFrame(
          cacheKey: cacheKey,
          dataType: 'sector',
          payloadJson: jsonEncode([for (final row in rows) row.toJson()]),
          source: EastmoneySectorProvider.source,
          ttl: sectorHotTtl,
        );
        return rows;
      }
    } catch (_) {
      // 落到过期缓存
    }
    final stale = await store.readFrame(cacheKey, allowStale: true);
    if (stale == null) return const [];
    return _decodeList(stale.payloadJson, SectorBoard.fromJson);
  }

  // ---------- 个股行业与概念 ----------

  /// 今日概念榜前 [top] 名的板块代码，用来给个股/命中打"热点"标记。
  /// 用代码而不是名称比对：东财同名板块可能重复出现，代码唯一。
  Future<Set<String>> hotConceptCodes({int top = sectorHotTop}) async {
    final boards = await _cachedBoards(sectorKindConcept, false);
    return {for (final board in _take(boards, top)) board.code};
  }

  /// 个股行业 + 概念。[hotCodes] 传入今日热点概念代码集（批量场景下由调用方
  /// 取一次复用）；不传则内部现取。行业/概念按天缓存，热点标记每次现算
  /// （榜单 5 分钟一变，不能跟着按天缓存走）。
  Future<StockSectors> sectorsOf(String symbol, {Set<String>? hotCodes}) async {
    final hot = hotCodes ?? await hotConceptCodes();
    final cached = await _readStockCache(symbol);
    final resolved = cached ?? await _fetchStockSectors(symbol);
    if (cached == null) await _writeStockCache(symbol, resolved);
    return StockSectors(
      symbol: symbol,
      industry: resolved.industry,
      concepts: resolved.concepts,
      hotConcepts: [
        for (final entry in resolved.conceptCodes.entries)
          if (hot.contains(entry.key)) entry.value,
      ],
    );
  }

  /// slist 拿个股所有所属板块，用概念板块全集过滤出概念；
  /// 行业单独走 stock/get 的 f127（slist 里行业是一串父子级，不好挑）。
  /// 两个请求并发，行业取数失败不影响概念，反之亦然。
  Future<_StockSectorRaw> _fetchStockSectors(String symbol) async {
    final results = await Future.wait([
      provider.stockIndustry(symbol).then<Object?>((value) => value,
          onError: (Object _) => null),
      provider.stockBoards(symbol).then<Object?>((value) => value,
          onError: (Object _) => null),
      conceptBoardNames().then<Object?>((value) => value,
          onError: (Object _) => null),
    ]);
    final industry = (results[0] as String?) ?? '';
    final boards = (results[1] as List<StockBoardRef>?) ?? const [];
    final conceptNames = (results[2] as Map<String, String>?) ?? const {};
    // 概念全集拿不到时不做过滤会混进地域/指数成分板块，宁可留空
    final conceptCodes = <String, String>{
      for (final board in boards)
        if (conceptNames.containsKey(board.code) && board.name != industry)
          board.code: board.name,
    };
    return _StockSectorRaw(
      industry: industry,
      conceptCodes: conceptCodes,
    );
  }

  /// 东财概念板块全集（代码 → 名称），按天缓存。
  /// 用它把 slist 返回的"所属板块"过滤成真正的概念板块
  /// （地域板块、指数成分等不在概念榜里的会被滤掉）。
  Future<Map<String, String>> conceptBoardNames({bool refresh = false}) async {
    if (!refresh) {
      final raw = await store.getState(sectorConceptBoardsKey);
      if (raw != null) {
        try {
          final data = (jsonDecode(raw) as Map).cast<String, Object?>();
          final boards = (data['boards'] as Map?)?.cast<String, Object?>();
          if (data['built_at'] == _today && boards != null && boards.isNotEmpty) {
            return {for (final entry in boards.entries) entry.key: '${entry.value}'};
          }
        } catch (_) {
          // 缓存损坏按无缓存处理
        }
      }
    }
    final boards = await provider.boards(sectorKindConcept, limit: 2000);
    final map = <String, String>{
      for (final board in boards)
        if (board.code.isNotEmpty) board.code: board.name,
    };
    if (map.isNotEmpty) {
      await store.setState(
        sectorConceptBoardsKey,
        jsonEncode({'built_at': _today, 'boards': map}),
      );
    }
    return map;
  }

  Future<_StockSectorRaw?> _readStockCache(String symbol) async {
    final raw = await store.getState('$sectorStatePrefix$symbol');
    if (raw == null) return null;
    try {
      final data = (jsonDecode(raw) as Map).cast<String, Object?>();
      if (data['checked_at'] != _today) return null;
      final codes = (data['concept_codes'] as Map?)?.cast<String, Object?>();
      return _StockSectorRaw(
        industry: (data['industry'] as String?) ?? '',
        conceptCodes: {
          for (final entry in (codes ?? const {}).entries)
            entry.key: '${entry.value}',
        },
      );
    } catch (_) {
      return null; // 缓存损坏按无缓存处理
    }
  }

  Future<void> _writeStockCache(String symbol, _StockSectorRaw raw) =>
      store.setState(
        '$sectorStatePrefix$symbol',
        jsonEncode({
          'checked_at': _today,
          'industry': raw.industry,
          'concept_codes': raw.conceptCodes,
        }),
      );

  static List<T> _take<T>(List<T> rows, int limit) =>
      rows.length > limit ? rows.sublist(0, limit) : rows;

  static List<T> _decodeList<T>(
      String payloadJson, T Function(Map<String, Object?>) fromJson) {
    try {
      return [
        for (final row in jsonDecode(payloadJson) as List)
          fromJson((row as Map).cast<String, Object?>()),
      ];
    } catch (_) {
      return const [];
    }
  }
}

/// 个股板块的可缓存部分（不含随榜单变化的热点标记）
class _StockSectorRaw {
  final String industry;

  /// 概念板块代码 → 名称（有序，保持 slist 返回顺序）
  final Map<String, String> conceptCodes;

  const _StockSectorRaw({required this.industry, required this.conceptCodes});

  List<String> get concepts => conceptCodes.values.toList();
}
