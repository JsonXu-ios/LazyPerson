/// 主界面：市场切换 → 信号条 → K 线主图 → MACD/LON 副图 → 底部操作。
/// 布局对齐网页版 V3.2 行情终端（chart-first），按手机竖屏调整。
library;

import 'package:flutter/material.dart';

import '../data/sync_service.dart';
import '../logic/market_panels.dart';
import '../state/band_scan_controller.dart';
import '../state/home_controller.dart';
import '../theme/app_theme.dart';
import '../utils/format.dart';
import 'band_scan_screen.dart';
import 'widgets/indicator_chart.dart';
import 'widgets/kline_chart.dart';
import 'widgets/summary_sheet.dart';
import 'widgets/watchlist_sheet.dart';

const _periods = ['day', 'week', 'month'];
const _periodLabels = {'day': '日K', 'week': '周K', 'month': '月K'};

class HomeScreen extends StatefulWidget {
  final HomeController controller;

  const HomeScreen({super.key, required this.controller});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int? _hoverIndex;
  BandScanController? _bandScanController;

  HomeController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.bootstrap();
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    _bandScanController?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _openWatchlist() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => WatchlistSheet(controller: controller),
    );
  }

  void _openSummary() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SummarySheet(controller: controller),
    );
  }

  void _openBandScan() {
    final band =
        _bandScanController ??= BandScanController(controller.repository);
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (routeContext) => BandScanScreen(
        controller: band,
        onSelect: (symbol) {
          controller.selectSymbol(symbol);
          Navigator.of(routeContext).pop();
        },
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final displayKline = controller.displayKline;
    final quote = controller.selectedQuote;

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _StatusBar(controller: controller),
            if (controller.syncProgress != null || controller.syncFailed)
              _SyncStrip(controller: controller),
            if (controller.notice.isNotEmpty)
              _NoticeBar(
                  notice: controller.notice, onClose: controller.clearNotice),
            _MarketTabs(controller: controller),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          quoteName(controller.selected, quote?.name),
                          style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: AppColors.text),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${controller.activeConfig.label} · ${controller.selected.isEmpty ? '暂无标的' : controller.selected} · ${qualityText(controller.klineQuality)}',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textFaint),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (quote?.price != null) ...[
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatFullPrice(quote!.price),
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: (quote.pctChg ?? 0) >= 0
                                  ? AppColors.rise
                                  : AppColors.fall),
                        ),
                        Text(
                          formatPercent(quote.pctChg),
                          style: TextStyle(
                              fontSize: 11,
                              color: (quote.pctChg ?? 0) >= 0
                                  ? AppColors.rise
                                  : AppColors.fall),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            _PeriodSwitch(controller: controller),
            Expanded(
              flex: 5,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: KlineChart(
                  payload: displayKline,
                  autoDrawing: controller.autoDrawing,
                  lineColors: controller.lineColors,
                  majorLineStep: controller.activeConfig.majorLineStep,
                  majorLineMinPercent:
                      controller.activeConfig.majorLineMinPercent ?? 0,
                  majorLineAnchor: controller.activeConfig.majorLineAnchor,
                  showLevelPrices: controller.activeConfig.showLevelPrices,
                  hoverIndex: _hoverIndex,
                  onHoverIndexChanged: (index) =>
                      setState(() => _hoverIndex = index),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
              child: IndicatorPanel(
                  kline: displayKline, hoverIndex: _hoverIndex),
            ),
            _BottomActions(
              onWatchlist: _openWatchlist,
              onSummary: _openSummary,
              // 八档局入口仅 A 股面板显示
              onBandScan: controller.activePanel == PanelKey.aShare
                  ? _openBandScan
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final HomeController controller;

  const _StatusBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      color: AppColors.panel,
      child: Row(
        children: [
          const Icon(Icons.candlestick_chart, size: 16, color: AppColors.warn),
          const SizedBox(width: 6),
          const Text('LazyPerson',
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text)),
          const Spacer(),
          Text(qualityText(controller.quoteQuality),
              style:
                  const TextStyle(fontSize: 10, color: AppColors.textFaint)),
          const SizedBox(width: 8),
          SizedBox(
            width: 30,
            height: 30,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              onPressed: controller.loading ? null : controller.refreshAll,
              icon: controller.loading
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}

/// 顶部全市场同步条：进度 + 文案，失败可点按重试
class _SyncStrip extends StatelessWidget {
  final HomeController controller;

  const _SyncStrip({required this.controller});

  String get _text {
    if (controller.syncFailed) return '全市场数据同步中断，点按重试（已同步部分可用）';
    final progress = controller.syncProgress;
    if (progress == null) return '';
    switch (progress.phase) {
      case SyncPhase.listing:
        return '正在获取沪深股票清单 (${progress.listLoaded}/${progress.listTotal == 0 ? '…' : progress.listTotal})';
      case SyncPhase.klines:
        return '同步日线 ${progress.klineDone}/${progress.klineTotal} 只${controller.syncEtaText}';
      case SyncPhase.pruning:
        return '正在整理本地数据…';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final failed = controller.syncFailed;
    return GestureDetector(
      onTap: failed ? controller.retrySync : null,
      child: Container(
        color: failed
            ? AppColors.rise.withValues(alpha: 0.12)
            : AppColors.panel,
        child: Column(
          children: [
            if (!failed)
              LinearProgressIndicator(
                value: controller.syncProgress?.phase == SyncPhase.idle
                    ? null
                    : controller.syncProgress?.ratio,
                minHeight: 3,
                backgroundColor: AppColors.grid,
                color: AppColors.warn,
              ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              child: Row(
                children: [
                  Icon(
                    failed ? Icons.error_outline : Icons.cloud_download_outlined,
                    size: 12,
                    color: failed ? AppColors.rise : AppColors.warn,
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: Text(
                      _text,
                      style: TextStyle(
                          fontSize: 10,
                          color: failed ? AppColors.rise : AppColors.textMuted),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if ((controller.syncProgress?.errorCount ?? 0) > 0)
                    Text('${controller.syncProgress!.errorCount} 只失败',
                        style: const TextStyle(
                            fontSize: 10, color: AppColors.warn)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticeBar extends StatelessWidget {
  final String notice;
  final VoidCallback onClose;

  const _NoticeBar({required this.notice, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.warn.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(notice,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11, color: AppColors.warn)),
          ),
          GestureDetector(
            onTap: onClose,
            child: const Icon(Icons.close, size: 14, color: AppColors.warn),
          ),
        ],
      ),
    );
  }
}

class _MarketTabs extends StatelessWidget {
  final HomeController controller;

  const _MarketTabs({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
      child: Row(
        children: [
          for (final panel in marketPanels) ...[
            Expanded(
              child: GestureDetector(
                onTap: () => controller.setPanel(panel.key),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  decoration: BoxDecoration(
                    color: controller.activePanel == panel.key
                        ? AppColors.panelBorder
                        : AppColors.panel,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: controller.activePanel == panel.key
                          ? AppColors.accent
                          : AppColors.panelBorder,
                    ),
                  ),
                  child: Column(
                    children: [
                      Text(panel.label,
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: controller.activePanel == panel.key
                                  ? AppColors.text
                                  : AppColors.textMuted)),
                      Text(
                        '${controller.watchlist.where((item) => panelForAsset(symbol: item.symbol, market: item.market, groupName: item.groupName, note: item.note) == panel.key).length} 个',
                        style: const TextStyle(
                            fontSize: 9, color: AppColors.textFaint),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (panel != marketPanels.last) const SizedBox(width: 6),
          ],
        ],
      ),
    );
  }
}

class _PeriodSwitch extends StatelessWidget {
  final HomeController controller;

  const _PeriodSwitch({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 0),
      child: Row(
        children: [
          for (final item in _periods) ...[
            Expanded(
              child: GestureDetector(
                onTap: () => controller.setPeriod(item),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  decoration: BoxDecoration(
                    color: controller.period == item
                        ? AppColors.axisBorder
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    _periodLabels[item] ?? item,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 11,
                        color: controller.period == item
                            ? AppColors.text
                            : AppColors.textFaint),
                  ),
                ),
              ),
            ),
            if (item != _periods.last) const SizedBox(width: 4),
          ],
        ],
      ),
    );
  }
}

class _BottomActions extends StatelessWidget {
  final VoidCallback onWatchlist;
  final VoidCallback onSummary;
  final VoidCallback? onBandScan;

  const _BottomActions({
    required this.onWatchlist,
    required this.onSummary,
    this.onBandScan,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onWatchlist,
              icon: const Icon(Icons.search, size: 15),
              label: const Text('自选资产', style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: onSummary,
              icon: const Icon(Icons.star_border, size: 15),
              label: const Text('资产信息', style: TextStyle(fontSize: 12)),
            ),
          ),
          if (onBandScan != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: onBandScan,
                icon: const Icon(Icons.grid_view, size: 15),
                label: const Text('八档局', style: TextStyle(fontSize: 12)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
