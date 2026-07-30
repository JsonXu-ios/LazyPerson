/// 数据源联网冒烟：验证各 provider 对沪深 A 股都能拉到行情、K 线与财务。
/// 运行：dart run tool/smoke_providers.dart
// ignore_for_file: avoid_print
library;

import 'package:lazyperson/data/providers/eastmoney_fundamentals_provider.dart';
import 'package:lazyperson/data/providers/eastmoney_provider.dart';
import 'package:lazyperson/data/providers/tencent_provider.dart';

Future<void> main() async {
  final tencent = TencentProvider();
  final eastmoney = EastmoneyProvider();
  final fundamentals = EastmoneyFundamentalsProvider();

  Future<void> run(String label, Future<String> Function() task) async {
    try {
      print('[OK] $label -> ${await task()}');
    } catch (exc) {
      print('[FAIL] $label -> $exc');
    }
  }

  await run('腾讯 A股行情 600519,000001', () async {
    final quotes = await tencent.realtimeQuotes(['600519', '000001']);
    return quotes.map((q) => '${q.symbol} ${q.name} ${q.price}').join(' | ');
  });

  await run('腾讯 日K 002138 (90天)', () async {
    final bars = await tencent.kline('002138', 'day',
        start: DateTime.now()
            .subtract(const Duration(days: 95))
            .toIso8601String()
            .substring(0, 10));
    return '${bars.length} bars, latest ${bars.last.time} close=${bars.last.close}';
  });

  await run('腾讯 5分钟K 600519', () async {
    final bars = await tencent.kline('600519', '5m');
    return '${bars.length} bars, latest ${bars.last.time}';
  });

  await run('东财 清单快照第1页', () async {
    final page = await eastmoney.fullMarketSnapshotPage(1);
    final first = page.quotes.first;
    return 'total=${page.total}, first=${first.symbol} ${first.name} ${first.price}';
  });

  await run('东财 日K 300750', () async {
    final bars = await eastmoney.kline('300750', 'day', start: '2026-04-01');
    return '${bars.length} bars, latest ${bars.last.time} close=${bars.last.close}';
  });

  await run('东财 估值 600519', () async {
    final valuation = await fundamentals.valuation('600519');
    return 'PE=${valuation.pe} PB=${valuation.pb} 市值=${valuation.marketCap}';
  });

  await run('东财 财务 600519', () async {
    final data = await fundamentals.fundamentals('600519');
    final latest = data.latestReport;
    return '${data.name} ${data.reports.length}期业绩 ${data.dividends.length}条分红'
        '，最新 ${latest?.label} 归母=${latest?.parentNetprofit}';
  });
}
