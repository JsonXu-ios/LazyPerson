/// 主界面（HUD 方案 1d，稿 09）：顶栏 → 同步条 → 标的头 → 周期/档位轨
/// → K 线主图（取景框）→ MACD/LON 副图 → 底部操作浮层。
/// 只做沪深 A 股，没有市场切换。
library;

import 'package:flutter/material.dart';

import '../data/sync_service.dart';
import '../logic/level_rules.dart';
import '../state/band_scan_controller.dart';
import '../state/home_controller.dart';
import '../theme/app_theme.dart';
import '../theme/hud.dart';
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
    final band = _bandScanController ??= BandScanController(
      controller.repository,
    );
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (routeContext) => BandScanScreen(
          controller: band,
          onSelect: (symbol) {
            controller.selectSymbol(symbol);
            Navigator.of(routeContext).pop();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final displayKline = controller.displayKline;
    final quote = controller.selectedQuote;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: hudBackgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusBar(controller: controller),
              if (controller.syncProgress != null || controller.syncFailed)
                _SyncStrip(controller: controller),
              if (controller.notice.isNotEmpty)
                _NoticeBar(
                  notice: controller.notice,
                  onClose: controller.clearNotice,
                ),
              _SymbolHead(controller: controller, quote: quote),
              _PeriodSwitch(controller: controller),
              Expanded(
                flex: 5,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                  child: HudBrackets(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(10),
                      child: KlineChart(
                        payload: displayKline,
                        autoDrawing: controller.autoDrawing,
                        majorLineStep: controller.activeConfig.majorLineStep,
                        majorLineMinPercent:
                            controller.activeConfig.majorLineMinPercent ?? 0,
                        majorLineAnchor:
                            controller.activeConfig.majorLineAnchor,
                        showLevelPrices:
                            controller.activeConfig.showLevelPrices,
                        hoverIndex: _hoverIndex,
                        onHoverIndexChanged: (index) =>
                            setState(() => _hoverIndex = index),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
                child: IndicatorPanel(
                  kline: displayKline,
                  hoverIndex: _hoverIndex,
                ),
              ),
              _BottomActions(
                onWatchlist: _openWatchlist,
                onSummary: _openSummary,
                onBandScan: _openBandScan,
              ),
            ],
          ),
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: HudPanel(
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(
              Icons.candlestick_chart,
              size: 24,
              color: AppColors.warn,
            ),
            const SizedBox(width: 8),
            const Text(
              'LazyPerson',
              style: TextStyle(
                fontSize: FontSize.screenTitle,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              ),
            ),
            const SizedBox(width: 8),
            // 纯装饰，窄屏优先让它被截，不要挤掉右侧的 LIVE 与刷新
            Flexible(
              child: Text(
                'MARKET HUD v3.2',
                overflow: TextOverflow.clip,
                softWrap: false,
                style: mono(
                  size: FontSize.capsLabel,
                  color: AppColors.accent,
                  letterSpacing: 3.2,
                ),
              ),
            ),
            const SizedBox(width: 8),
            HudLiveBadge(live: !controller.loading),
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
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh, color: AppColors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 顶部全市场同步条：分段进度 + 文案，失败可点按重试
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
    final progress = controller.syncProgress;
    final ratio = progress?.phase == SyncPhase.idle ? null : progress?.ratio;
    return GestureDetector(
      onTap: failed ? controller.retrySync : null,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'SYNC',
                  style: mono(
                    size: FontSize.capsLabel,
                    color: failed ? AppColors.rise : AppColors.warn,
                    weight: FontWeight.w600,
                    letterSpacing: 2.6,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _text,
                    style: TextStyle(
                      fontSize: FontSize.caption,
                      color: failed ? AppColors.rise : AppColors.textMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (ratio != null && !failed)
                  Text(
                    '${(ratio * 100).toStringAsFixed(0)}%',
                    style: mono(
                      size: FontSize.tableNumber,
                      color: AppColors.warn,
                    ),
                  ),
                if ((progress?.errorCount ?? 0) > 0) ...[
                  const SizedBox(width: 6),
                  Text(
                    '${progress!.errorCount} 只失败',
                    style: mono(
                      size: FontSize.tableNumber,
                      color: AppColors.rise,
                    ),
                  ),
                ],
              ],
            ),
            if (!failed) ...[
              const SizedBox(height: 5),
              HudSegmentBar(ratio: ratio),
            ],
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: HudPanel(
        radius: 10,
        tint: AppColors.warn,
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: Row(
          children: [
            Expanded(
              child: Text(
                notice,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: FontSize.body,
                  color: AppColors.warn,
                ),
              ),
            ),
            GestureDetector(
              onTap: onClose,
              child: const Icon(Icons.close, size: 14, color: AppColors.warn),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标的头：名称 + 代码/市场/数据源 + 现价（发光）+ 涨跌实心徽标
class _SymbolHead extends StatelessWidget {
  final HomeController controller;
  final dynamic quote;

  const _SymbolHead({required this.controller, required this.quote});

  @override
  Widget build(BuildContext context) {
    final pct = quote?.pctChg as double?;
    final tone = (pct ?? 0) >= 0 ? AppColors.rise : AppColors.fall;
    final market = quote?.market as String?;
    final source = controller.klineQuality?.source ?? '';
    final subParts = [
      controller.selected.isEmpty ? '暂无标的' : controller.selected,
      if (market != null && market.isNotEmpty) market,
      if (source.isNotEmpty) source.toUpperCase(),
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  quoteName(controller.selected, quote?.name as String?),
                  style: const TextStyle(
                    fontSize: FontSize.symbolName,
                    fontWeight: FontWeight.w700,
                    height: 1.1,
                    color: AppColors.text,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  subParts.join(' · '),
                  style: mono(
                    size: FontSize.legend,
                    color: AppColors.textFaint,
                    letterSpacing: 1,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (quote?.price != null)
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                GlowText(
                  formatFullPrice(quote.price as double?),
                  size: FontSize.price,
                  color: tone,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Text(
                      _signed(quote.change as double?),
                      style: mono(size: FontSize.secondaryNumber, color: tone),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: tone,
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        _signedPercent(pct),
                        style: mono(
                          size: FontSize.secondaryNumber,
                          color: const Color(0xFF050914),
                          weight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
        ],
      ),
    );
  }

  String _signed(double? value) {
    if (value == null) return '-';
    return '${value >= 0 ? '+' : ''}${value.toStringAsFixed(3)}';
  }

  String _signedPercent(double? value) {
    if (value == null) return '-';
    return '${value >= 0 ? '+' : ''}${value.toStringAsFixed(2)}%';
  }
}

/// 顶部档位轨要显示的“已站上的最高主线”。判定沿用 level_rules 的
/// isMajorLevel，不新写规则：主线按 percent 升序排成八格轨，
/// 现价涨幅（相对 0% 基准）过了哪条就点亮哪格。
class _CrossedLevel {
  final int railIndex;
  final double pct;

  const _CrossedLevel(this.railIndex, this.pct);
}

_CrossedLevel? _crossedLevel(HomeController controller) {
  final auto = controller.autoDrawing;
  final close = auto?.latest.close;
  final base = auto?.base.price;
  if (auto == null || close == null || base == null || base <= 0) return null;
  final config = controller.activeConfig;
  final majors =
      auto.levels
          .where(
            (level) => isMajorLevel(
              level,
              majorLineStep: config.majorLineStep,
              majorLineMinPercent: config.majorLineMinPercent ?? 0,
              majorLineAnchor: config.majorLineAnchor,
            ),
          )
          .toList()
        ..sort((a, b) => a.percent.compareTo(b.percent));
  if (majors.isEmpty) return null;
  final pct = (close / base - 1) * 100;
  var index = -1;
  for (var i = 0; i < majors.length; i++) {
    if (pct >= majors[i].percent) index = i;
  }
  return _CrossedLevel(index.clamp(0, 7), pct);
}

class _PeriodSwitch extends StatelessWidget {
  final HomeController controller;

  const _PeriodSwitch({required this.controller});

  @override
  Widget build(BuildContext context) {
    final crossed = _crossedLevel(controller);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: AppColors.panel.withValues(alpha: 0.8),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                for (final item in _periods) ...[
                  GestureDetector(
                    onTap: () => controller.setPeriod(item),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: controller.period == item
                            ? AppColors.hudFillActive
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _periodLabels[item] ?? item,
                        style: TextStyle(
                          fontSize: FontSize.secondaryNumber,
                          fontWeight: controller.period == item
                              ? FontWeight.w700
                              : FontWeight.w500,
                          color: controller.period == item
                              ? AppColors.text
                              : AppColors.textFaint,
                        ),
                      ),
                    ),
                  ),
                  if (item != _periods.last) const SizedBox(width: 2),
                ],
              ],
            ),
          ),
          const Spacer(),
          if (crossed != null) ...[
            HudLevelRail(activeIndex: crossed.railIndex),
            const SizedBox(width: 8),
            Text(
              '${crossed.pct >= 0 ? '+' : ''}${crossed.pct.toStringAsFixed(1)}%',
              style: mono(
                size: FontSize.secondaryNumber,
                color: AppColors.warn,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BottomActions extends StatelessWidget {
  final VoidCallback onWatchlist;
  final VoidCallback onSummary;
  final VoidCallback onBandScan;

  const _BottomActions({
    required this.onWatchlist,
    required this.onSummary,
    required this.onBandScan,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      child: HudPanel(
        radius: 16,
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              child: _ActionCell(
                icon: Icons.search,
                label: '自选资产',
                onTap: onWatchlist,
              ),
            ),
            Expanded(
              child: _ActionCell(
                icon: Icons.insights_outlined,
                label: '资产信息',
                onTap: onSummary,
              ),
            ),
            Expanded(
              child: _ActionCell(
                icon: Icons.grid_view,
                label: '八档局',
                onTap: onBandScan,
                highlight: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool highlight;

  const _ActionCell({
    required this.icon,
    required this.label,
    required this.onTap,
    this.highlight = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = highlight ? AppColors.accent : AppColors.textMuted;
    final cell = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(height: 5),
        Text(
          label,
          style: TextStyle(fontSize: FontSize.body, color: color),
        ),
      ],
    );
    if (!highlight) {
      return InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: cell,
        ),
      );
    }
    return HudPanel(
      radius: 10,
      active: true,
      glow: true,
      padding: const EdgeInsets.symmetric(vertical: 8),
      onTap: onTap,
      child: cell,
    );
  }
}
