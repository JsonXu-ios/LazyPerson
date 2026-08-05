/// 资产信息浮层（HUD 方案 1d）：现价摘要、财务概览、关键位、线位颜色、删除自选。
/// 对齐 frontend/src/components/StockSummary.tsx。
library;

import 'package:flutter/material.dart';

import '../../logic/auto_drawing.dart';
import '../../state/home_controller.dart';
import '../../theme/app_theme.dart';
import '../../theme/hud.dart';
import '../../utils/format.dart';
import 'fundamentals_section.dart';
import 'hud_sheet.dart';
import 'sector_tags.dart';

class SummarySheet extends StatefulWidget {
  final HomeController controller;

  const SummarySheet({super.key, required this.controller});

  @override
  State<SummarySheet> createState() => _SummarySheetState();
}

class _SummarySheetState extends State<SummarySheet> {
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

  @override
  Widget build(BuildContext context) {
    final quote = controller.selectedQuote;
    final latest = controller.latestBar;
    final auto = controller.autoDrawing;

    return HudSheet(
      heightFactor: 0.88,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  quoteName(controller.selected, quote?.name),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: FontSize.screenTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                controller.selected,
                style: mono(
                  size: FontSize.legend,
                  color: AppColors.accent,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '行情 ${qualityText(controller.quoteQuality)} · K线 ${qualityText(controller.klineQuality)}',
            style: mono(size: FontSize.legend, color: AppColors.textDim),
          ),
          SectorTags(
            sectors: controller.repository.sectors,
            symbol: controller.selected,
          ),
          const SizedBox(height: 12),
          _metricGrid([
            ('现价', formatFullPrice(quote?.price ?? latest?.close)),
            ('涨跌幅', formatPercent(quote?.pctChg ?? latest?.pctChg)),
            ('今开', formatFullPrice(quote?.open ?? latest?.open)),
            ('昨收', formatFullPrice(quote?.preClose)),
            ('最高', formatFullPrice(quote?.high ?? latest?.high)),
            ('最低', formatFullPrice(quote?.low ?? latest?.low)),
            ('成交量', formatNumber(quote?.volume ?? latest?.volume)),
            ('成交额', formatNumber(quote?.amount ?? latest?.amount)),
          ]),
          FundamentalsSection(
            repository: controller.repository,
            symbol: controller.selected,
          ),
          if (auto != null) ...[
            const SizedBox(height: 16),
            _sectionTitle(
              '自动画线',
              status: trendLabel(auto.direction),
              statusColor: auto.direction == AutoTrendDirection.up
                  ? AppColors.rise
                  : auto.direction == AutoTrendDirection.down
                  ? AppColors.fall
                  : AppColors.textMuted,
            ),
            const SizedBox(height: 8),
            _metricGrid([
              ('窗口', '${auto.windowSize} 根'),
              (auto.base.label, formatFullPrice(auto.base.price)),
              (auto.target.label, formatFullPrice(auto.target.price)),
              if (auto.nearestLevel != null)
                (
                  '最近关键位',
                  '${auto.nearestLevel!.label} ${formatFullPrice(auto.nearestLevel!.price)}',
                ),
              if (auto.nearestDistancePct != null)
                ('距关键位', formatPercent(auto.nearestDistancePct)),
            ]),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    controller.refreshAll();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.refresh, size: 17),
                  label: const Text(
                    '强制刷新',
                    style: TextStyle(fontSize: FontSize.body),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // 八档局点进来的标的通常不在自选里，这里给个入口能直接加
              Expanded(
                child: controller.selectedInWatchlist
                    ? OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.rise,
                          side: BorderSide(
                            color: AppColors.rise.withValues(alpha: 0.5),
                          ),
                          backgroundColor: AppColors.rise.withValues(
                            alpha: 0.12,
                          ),
                        ),
                        onPressed: () {
                          controller.removeSymbol(controller.selected);
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.delete_outline, size: 17),
                        label: const Text(
                          '删除自选',
                          style: TextStyle(fontSize: FontSize.body),
                        ),
                      )
                    : OutlinedButton.icon(
                        onPressed: () {
                          controller.addSymbol(controller.selected);
                          Navigator.of(context).pop();
                        },
                        icon: const Icon(Icons.star_border, size: 17),
                        label: const Text(
                          '加入自选',
                          style: TextStyle(fontSize: FontSize.body),
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 段标题：粗体 + 1px 横线 + 可选状态词
  Widget _sectionTitle(String title, {String? status, Color? statusColor}) {
    return Row(
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: FontSize.secondaryNumber,
            fontWeight: FontWeight.w700,
            color: AppColors.text,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: AppColors.hudBorder)),
        if (status != null) ...[
          const SizedBox(width: 10),
          Text(
            status,
            style: mono(
              size: FontSize.legend,
              color: statusColor ?? AppColors.textMuted,
              weight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  /// 两列 HudPanel 网格（label 10 textFaint / value mono 11.5）
  Widget _metricGrid(List<(String, String)> items) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, value) in items)
          _MetricCell(label: label, value: value),
      ],
    );
  }
}

class _MetricCell extends StatelessWidget {
  final String label;
  final String value;

  const _MetricCell({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, _) => SizedBox(
        // 两列：父级 ListView 宽度减去 spacing 后二等分
        width: (MediaQuery.of(context).size.width - 32 - 8) / 2,
        child: HudPanel(
          radius: 10,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: FontSize.legend,
                  color: AppColors.textFaint,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                overflow: TextOverflow.ellipsis,
                style: mono(size: FontSize.tableNumber, color: AppColors.text),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
