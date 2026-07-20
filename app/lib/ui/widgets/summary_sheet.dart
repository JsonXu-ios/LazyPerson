/// 资产信息弹层：现价摘要、关键位、线位颜色设置、删除自选。
/// 对齐 frontend/src/components/StockSummary.tsx。
library;

import 'package:flutter/material.dart';

import '../../logic/auto_drawing.dart';
import '../../state/home_controller.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';

const _colorChoices = [
  '#f6d36b',
  '#f24d4d',
  '#1f6feb',
  '#ffffff',
  '#38bdf8',
  '#c084fc',
  '#f2a93b',
  '#00a884',
];

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

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.all(14),
        children: [
          Text(
            '${quoteName(controller.selected, quote?.name)} · ${controller.selected}',
            style: const TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, color: AppColors.text),
          ),
          const SizedBox(height: 4),
          Text('行情：${qualityText(controller.quoteQuality)} · K线：${qualityText(controller.klineQuality)}',
              style: const TextStyle(fontSize: 10, color: AppColors.textFaint)),
          const SizedBox(height: 12),
          _kvGrid([
            ('现价', formatFullPrice(quote?.price ?? latest?.close)),
            ('涨跌幅', formatPercent(quote?.pctChg ?? latest?.pctChg)),
            ('今开', formatFullPrice(quote?.open ?? latest?.open)),
            ('昨收', formatFullPrice(quote?.preClose)),
            ('最高', formatFullPrice(quote?.high ?? latest?.high)),
            ('最低', formatFullPrice(quote?.low ?? latest?.low)),
            ('成交量', formatNumber(quote?.volume ?? latest?.volume)),
            ('成交额', formatNumber(quote?.amount ?? latest?.amount)),
          ]),
          const SizedBox(height: 14),
          if (auto != null) ...[
            const Text('自动画线',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text)),
            const SizedBox(height: 6),
            _kvGrid([
              ('趋势', trendLabel(auto.direction)),
              ('窗口', '${auto.windowSize} 根'),
              (auto.base.label, formatFullPrice(auto.base.price)),
              (auto.target.label, formatFullPrice(auto.target.price)),
              if (auto.nearestLevel != null)
                ('最近关键位',
                    '${auto.nearestLevel!.label} ${formatFullPrice(auto.nearestLevel!.price)}'),
              if (auto.nearestDistancePct != null)
                ('距关键位', formatPercent(auto.nearestDistancePct)),
            ]),
            const SizedBox(height: 14),
            const Text('线位颜色',
                style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text)),
            const SizedBox(height: 6),
            for (final level in auto.levels)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: [
                    SizedBox(
                      width: 64,
                      child: Text(level.label,
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textMuted)),
                    ),
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        children: [
                          for (final hex in _colorChoices)
                            GestureDetector(
                              onTap: () =>
                                  controller.updateLineColor(level.label, hex),
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: colorFromHex(hex),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    width: 2,
                                    color: (controller.lineColors[level.label] ??
                                                defaultLineColors[level.label]) ==
                                            hex
                                        ? AppColors.accent
                                        : Colors.transparent,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () {
                    controller.refreshAll();
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.refresh, size: 15),
                  label: const Text('强制刷新', style: TextStyle(fontSize: 12)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.rise),
                  onPressed: () {
                    controller.removeSymbol(controller.selected);
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.delete_outline, size: 15),
                  label: const Text('删除自选', style: TextStyle(fontSize: 12)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _kvGrid(List<(String, String)> items) {
    return Wrap(
      runSpacing: 6,
      children: [
        for (final (label, value) in items)
          FractionallySizedBox(
            widthFactor: 0.5,
            child: Row(
              children: [
                Text('$label ',
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textFaint)),
                Expanded(
                  child: Text(value,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.text)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
