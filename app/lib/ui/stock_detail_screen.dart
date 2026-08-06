/// 个股详情页（HUD 方案 1d，稿 09）：返回栏 → 标的头 → 周期/档位轨 →
/// K 线主图（取景框）→ MACD/LON 副图 → 资产信息入口。
/// 由自选列表/八档局/热点板块点某只股票进入；底部导航保留在根页。
library;

import 'package:flutter/material.dart';

import '../logic/level_rules.dart';
import '../state/home_controller.dart';
import '../theme/app_theme.dart';
import '../theme/hud.dart';
import '../utils/format.dart';
import 'widgets/indicator_chart.dart';
import 'widgets/kline_chart.dart';
import 'widgets/summary_sheet.dart';

const _periods = ['day', 'week', 'month'];
const _periodLabels = {'day': '日K', 'week': '周K', 'month': '月K'};

class StockDetailScreen extends StatefulWidget {
  final HomeController controller;

  const StockDetailScreen({super.key, required this.controller});

  @override
  State<StockDetailScreen> createState() => _StockDetailScreenState();
}

class _StockDetailScreenState extends State<StockDetailScreen> {
  int? _hoverIndex;

  HomeController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _openSummary() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SummarySheet(controller: controller),
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
              _TopBar(controller: controller),
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
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                child: SizedBox(
                  height: 40,
                  child: FilledButton.icon(
                    onPressed: _openSummary,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.hudFillActive,
                      foregroundColor: AppColors.accent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: AppColors.hudBorderActive),
                      ),
                    ),
                    icon: const Icon(Icons.insights_outlined, size: 18),
                    label: const Text(
                      '资产信息',
                      style: TextStyle(
                        fontSize: FontSize.secondaryNumber,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 返回栏：返回 + 标的名 + LIVE + 刷新
class _TopBar extends StatelessWidget {
  final HomeController controller;

  const _TopBar({required this.controller});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 0),
      child: Row(
        children: [
          IconButton(
            iconSize: 22,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, color: AppColors.textMuted),
          ),
          Flexible(
            child: Text(
              'DETAIL · ${controller.selected}',
              overflow: TextOverflow.clip,
              softWrap: false,
              style: mono(
                size: FontSize.capsLabel,
                color: AppColors.accent,
                letterSpacing: 2.4,
              ),
            ),
          ),
          const Spacer(),
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
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
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
          // 行情未到时也渲染占位（'-'），保持头部高度恒定：
          // 否则现价列在数据到达后才出现，K线区域会被压缩产生跳动
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              GlowText(
                formatFullPrice(quote?.price as double?),
                size: FontSize.price,
                color: tone,
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    _signed(quote?.change as double?),
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
