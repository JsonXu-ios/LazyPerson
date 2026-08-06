/// 本地 sqlite 存储：沪深全量清单、90 天日 K、自选股、同步状态、短期缓存。
library;

import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';

class CachedFrame {
  final String payloadJson;
  final String source;
  final DateTime updatedAt;
  final DateTime expiresAt;

  const CachedFrame({
    required this.payloadJson,
    required this.source,
    required this.updatedAt,
    required this.expiresAt,
  });

  bool get stale => DateTime.now().isAfter(expiresAt);

  Object? decode() => jsonDecode(payloadJson);
}

class LocalStore {
  final Database db;

  LocalStore(this.db);

  static Future<LocalStore> open(String path) async {
    final db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) => createSchema(db),
    );
    return LocalStore(db);
  }

  static Future<void> createSchema(Database db) async {
    await db.execute('''
          CREATE TABLE symbols (
            symbol TEXT PRIMARY KEY,
            market TEXT NOT NULL DEFAULT '',
            name TEXT NOT NULL DEFAULT '',
            pinyin_abbr TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE watchlist (
            symbol TEXT PRIMARY KEY,
            group_name TEXT NOT NULL DEFAULT 'default',
            sort_order INTEGER NOT NULL DEFAULT 0,
            note TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE daily_bars (
            symbol TEXT NOT NULL,
            date TEXT NOT NULL,
            open REAL, high REAL, low REAL, close REAL,
            volume REAL, amount REAL, pct_chg REAL, turnover REAL,
            PRIMARY KEY (symbol, date)
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_daily_bars_date ON daily_bars(date)');
        await db.execute('''
          CREATE TABLE sync_state (
            symbol TEXT PRIMARY KEY,
            last_synced_date TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'pending'
          )
        ''');
        await db.execute('''
          CREATE TABLE frames (
            cache_key TEXT PRIMARY KEY,
            data_type TEXT NOT NULL DEFAULT '',
            symbol TEXT NOT NULL DEFAULT '',
            period TEXT NOT NULL DEFAULT '',
            payload_json TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL,
            expires_at TEXT NOT NULL
          )
        ''');
    await db.execute('''
          CREATE TABLE app_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
  }

  // ---------- app_state ----------

  Future<String?> getState(String key) async {
    final rows =
        await db.query('app_state', where: 'key = ?', whereArgs: [key]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  Future<void> setState(String key, String value) async {
    await db.insert('app_state', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// 按 key 前缀批量取（返回的 key 已去掉前缀）。
  /// 八档局纯本地扫描要读几百上千只股票的缓存标记，逐只 getState 就是上千次
  /// sqlite 往返；这里一次查询拿走整个前缀。
  Future<Map<String, String>> getStatesWithPrefix(String prefix) async {
    final rows = await db.query(
      'app_state',
      where: 'key LIKE ?',
      whereArgs: ['$prefix%'],
    );
    return {
      for (final row in rows)
        (row['key'] as String).substring(prefix.length): row['value'] as String,
    };
  }

  // ---------- symbols ----------

  Future<void> upsertSymbols(List<SymbolItem> items) async {
    if (items.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    final batch = db.batch();
    for (final item in items) {
      batch.insert(
        'symbols',
        {...item.toRow(), 'updated_at': now},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<int> symbolCount({String? market}) async {
    final result = market == null
        ? await db.rawQuery('SELECT COUNT(*) AS c FROM symbols')
        : await db.rawQuery(
            'SELECT COUNT(*) AS c FROM symbols WHERE market = ?', [market]);
    return (result.first['c'] as int?) ?? 0;
  }

  /// 删掉自选与清单里所有非 6 位数字代码的行（历史上种过的美股/黄金/加密）。
  /// 项目已收敛为纯 A 股，这些行留着会让整批行情请求失败。返回删除的自选条数。
  Future<int> purgeNonAShare() async {
    const notASharePattern = "symbol NOT GLOB '[0-9][0-9][0-9][0-9][0-9][0-9]'";
    final removed = await db.delete('watchlist', where: notASharePattern);
    await db.delete('symbols', where: notASharePattern);
    return removed;
  }

  Future<SymbolItem?> getSymbol(String symbol) async {
    final rows =
        await db.query('symbols', where: 'symbol = ?', whereArgs: [symbol]);
    return rows.isEmpty ? null : SymbolItem.fromRow(rows.first);
  }

  /// 本地搜索：代码前缀 / 名称包含 / 拼音首字母前缀
  Future<List<SymbolItem>> searchSymbols(String query, {int limit = 20}) async {
    final clean = query.trim();
    if (clean.isEmpty) return [];
    final upper = clean.toUpperCase();
    final rows = await db.query(
      'symbols',
      where: 'symbol LIKE ? OR name LIKE ? OR pinyin_abbr LIKE ?',
      whereArgs: ['$upper%', '%$clean%', '$upper%'],
      orderBy: 'symbol',
      limit: limit,
    );
    return rows.map(SymbolItem.fromRow).toList();
  }

  /// 本地清单中的沪深主板代码（60/00 开头），八档局腾讯行情兜底用
  Future<List<String>> mainBoardASymbols() async {
    final rows = await db.query(
      'symbols',
      columns: ['symbol'],
      where: "symbol LIKE '60%' OR symbol LIKE '00%'",
      orderBy: 'symbol',
    );
    final digits = RegExp(r'^\d{6}$');
    return [
      for (final row in rows)
        if (digits.hasMatch(row['symbol'] as String)) row['symbol'] as String,
    ];
  }

  // ---------- watchlist ----------

  Future<List<WatchlistItem>> listWatchlist() async {
    final rows = await db.rawQuery('''
      SELECT w.symbol, w.group_name, w.sort_order, w.note,
             COALESCE(s.market, '') AS market, COALESCE(s.name, '') AS name
      FROM watchlist w LEFT JOIN symbols s ON s.symbol = w.symbol
      ORDER BY w.group_name, w.sort_order, w.symbol
    ''');
    return rows
        .map((row) => WatchlistItem(
              symbol: row['symbol'] as String,
              market: row['market'] as String,
              name: row['name'] as String,
              groupName: row['group_name'] as String,
              sortOrder: (row['sort_order'] as int?) ?? 0,
              note: row['note'] as String,
            ))
        .toList();
  }

  Future<void> addWatchlist(String symbol, String groupName,
      {String note = ''}) async {
    final result = await db.rawQuery(
        'SELECT COALESCE(MAX(sort_order), 0) + 1 AS next FROM watchlist WHERE group_name = ?',
        [groupName]);
    final next = (result.first['next'] as int?) ?? 1;
    await db.insert(
      'watchlist',
      {'symbol': symbol, 'group_name': groupName, 'sort_order': next, 'note': note},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> removeWatchlist(String symbol) async {
    await db.delete('watchlist', where: 'symbol = ?', whereArgs: [symbol]);
  }

  // ---------- daily bars ----------

  Future<void> upsertDailyBars(String symbol, List<KlineBar> bars) async {
    if (bars.isEmpty) return;
    final batch = db.batch();
    for (final bar in bars) {
      if (bar.time.isEmpty) continue;
      batch.insert(
        'daily_bars',
        _barRow(symbol, bar),
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  static Map<String, Object?> _barRow(String symbol, KlineBar bar) => {
        'symbol': symbol,
        'date': bar.time,
        'open': bar.open,
        'high': bar.high,
        'low': bar.low,
        'close': bar.close,
        'volume': bar.volume,
        'amount': bar.amount,
        'pct_chg': bar.pctChg,
        'turnover': bar.turnover,
      };

  /// 多只股票的日 K 一次性批量 upsert（快照吸收用）。
  /// 逐只调 [upsertDailyBars] 会对全市场 5000 只各提交一次 batch，
  /// 在扫描里就是几秒的纯开销；这里合成一个 batch 一次提交。
  Future<void> upsertDailyBarsBatch(Map<String, List<KlineBar>> barsBySymbol) async {
    if (barsBySymbol.isEmpty) return;
    final batch = db.batch();
    var queued = 0;
    for (final entry in barsBySymbol.entries) {
      for (final bar in entry.value) {
        if (bar.time.isEmpty) continue;
        batch.insert(
          'daily_bars',
          _barRow(entry.key, bar),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        queued += 1;
      }
    }
    if (queued == 0) return;
    await batch.commit(noResult: true);
  }

  Future<List<KlineBar>> getDailyBars(String symbol) async {
    final rows = await db.query('daily_bars',
        where: 'symbol = ?', whereArgs: [symbol], orderBy: 'date');
    return rows.map(_barFromRow).toList();
  }

  /// 一批股票的日 K（symbol → 按日期升序的 bar）。
  /// 八档局扫描要遍历几千只，逐只 getDailyBars 是几千次 sqlite 往返；
  /// 调用方按 200 只左右分块调用，既省往返又不会把整库读进内存。
  Future<Map<String, List<KlineBar>>> dailyBarsFor(List<String> symbols) async {
    if (symbols.isEmpty) return {};
    final placeholders = List.filled(symbols.length, '?').join(',');
    final rows = await db.query(
      'daily_bars',
      where: 'symbol IN ($placeholders)',
      whereArgs: symbols,
      orderBy: 'symbol, date',
    );
    final result = <String, List<KlineBar>>{};
    for (final row in rows) {
      (result[row['symbol'] as String] ??= <KlineBar>[]).add(_barFromRow(row));
    }
    return result;
  }

  /// 本地已有日 K 的股票代码集合（补齐数据时用来找“一根都没有”的股票）
  /// 数据新鲜度统计：本地日 K 已到 [tradeDate] 的股票数、清单总数。
  /// 自选页顶部显示"已最新 X / 待更新 Y"用。
  Future<({int fresh, int total})> freshnessCounts(String tradeDate) async {
    final freshRow = await db.rawQuery(
        'SELECT COUNT(DISTINCT symbol) AS c FROM daily_bars WHERE date = ?',
        [tradeDate]);
    final totalRow = await db.rawQuery('SELECT COUNT(*) AS c FROM symbols');
    return (
      fresh: (freshRow.first['c'] as int?) ?? 0,
      total: (totalRow.first['c'] as int?) ?? 0,
    );
  }

  Future<Set<String>> symbolsWithBars() async {
    final rows = await db.rawQuery('SELECT DISTINCT symbol FROM daily_bars');
    return {for (final row in rows) row['symbol'] as String};
  }

  static KlineBar _barFromRow(Map<String, Object?> row) => KlineBar(
        time: row['date'] as String,
        open: row['open'] as double?,
        high: row['high'] as double?,
        low: row['low'] as double?,
        close: row['close'] as double?,
        volume: row['volume'] as double?,
        amount: row['amount'] as double?,
        pctChg: row['pct_chg'] as double?,
        turnover: row['turnover'] as double?,
      );

  Future<String?> latestDailyDate(String symbol) async {
    final rows = await db.rawQuery(
        'SELECT MAX(date) AS latest FROM daily_bars WHERE symbol = ?', [symbol]);
    return rows.first['latest'] as String?;
  }

  /// 全市场本地日 K 的最新交易日（同步状态展示用）；null = 无数据
  Future<String?> latestDailyDateGlobal() async {
    final rows =
        await db.rawQuery('SELECT MAX(date) AS latest FROM daily_bars');
    return rows.first['latest'] as String?;
  }

  /// 删除早于 cutoffDate（YYYY-MM-DD）的日 K，保持库体积恒定
  Future<int> pruneDailyBars(String cutoffDate) async {
    return db
        .delete('daily_bars', where: 'date < ?', whereArgs: [cutoffDate]);
  }

  // ---------- sync state ----------

  Future<void> setSyncState(String symbol, String lastSyncedDate, String status) async {
    await db.insert(
      'sync_state',
      {'symbol': symbol, 'last_synced_date': lastSyncedDate, 'status': status},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, String>> syncedDates() async {
    final rows = await db.query('sync_state', where: "status = 'done'");
    return {
      for (final row in rows)
        row['symbol'] as String: row['last_synced_date'] as String,
    };
  }

  /// 指定同步状态的股票代码（'error' = 初始同步失败，补齐数据入口用）
  Future<List<String>> symbolsWithSyncStatus(String status) async {
    final rows = await db.query('sync_state',
        columns: ['symbol'], where: 'status = ?', whereArgs: [status]);
    return [for (final row in rows) row['symbol'] as String];
  }

  /// 清空逐只同步状态（强制全量刷新：让 runInitialSync 重新拉每一只）
  Future<void> clearSyncState() async => db.delete('sync_state');

  /// 本地清单里的全部代码（补齐数据时用来找缺日 K 的股票）
  Future<List<String>> allSymbols() async {
    final rows = await db.query('symbols', columns: ['symbol']);
    return [for (final row in rows) row['symbol'] as String];
  }

  // ---------- frames（短期 JSON 缓存） ----------

  Future<CachedFrame?> readFrame(String cacheKey, {bool allowStale = false}) async {
    final rows =
        await db.query('frames', where: 'cache_key = ?', whereArgs: [cacheKey]);
    if (rows.isEmpty) return null;
    final row = rows.first;
    final frame = CachedFrame(
      payloadJson: row['payload_json'] as String,
      source: row['source'] as String,
      updatedAt: DateTime.parse(row['updated_at'] as String),
      expiresAt: DateTime.parse(row['expires_at'] as String),
    );
    if (!allowStale && frame.stale) return null;
    return frame;
  }

  Future<void> writeFrame({
    required String cacheKey,
    required String dataType,
    required String payloadJson,
    required String source,
    String symbol = '',
    String period = '',
    required Duration ttl,
  }) async {
    final now = DateTime.now();
    await db.insert(
      'frames',
      {
        'cache_key': cacheKey,
        'data_type': dataType,
        'symbol': symbol,
        'period': period,
        'payload_json': payloadJson,
        'source': source,
        'updated_at': now.toIso8601String(),
        'expires_at': now.add(ttl).toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> close() => db.close();
}
