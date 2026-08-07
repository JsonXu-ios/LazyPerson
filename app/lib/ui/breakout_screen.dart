/// 破势：按已突破的最高主线（20/50/80/110/…）给命中股分组。
/// 与八档局共用同一次扫描结果（BandScanController.hits），只换一套分组口径：
/// 八档局看"落在哪个档位区间"（分界 20/40/70/100），破势看"最近站上了哪条主线"。
library;

import 'package:flutter/material.dart';

import '../logic/band_scanner.dart';
import '../state/band_scan_controller.dart';
import '../theme/app_theme.dart';
import 'widgets/band_hit_card.dart';

class BreakoutScreen extends StatefulWidget {
  final BandScanController controller;
  final ValueChanged<String> onSelect;

  const BreakoutScreen({
    super.key,
    required this.controller,
    required this.onSelect,
  });

  @override
  State<BreakoutScreen> createState() => _BreakoutScreenState();
}

class _BreakoutScreenState extends State<BreakoutScreen> {
  /// 默认看「20→50」组（站上50主线的那批）
  int _stage = 2;

  BandScanController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.restore();
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 只看真正完成过一次主线突破的（站上50及以上，stage≥2）
  Map<int, List<BandHit>> get _byStage {
    final grouped = <int, List<BandHit>>{};
    for (final hit in controller.visibleHits) {
      final stage = hit.breakStage ?? 0;
      if (stage < 2) continue;
      grouped.putIfAbsent(stage, () => []).add(hit);
    }
    for (final list in grouped.values) {
      list.sort((a, b) => b.pct.compareTo(a.pct));
    }
    return grouped;
  }

  @override
  Widget build(BuildContext context) {
    final grouped = _byStage;
    final rows = grouped[_stage] ?? const <BandHit>[];
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: hudBackgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              _stageTabs(grouped),
              if (controller.hits.isEmpty)
                const Expanded(
                  child: Center(
                    child: Text(
                      '请先到「八档局」执行一次扫描',
                      style: TextStyle(
                        fontSize: FontSize.secondaryNumber,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ),
                )
              else
                Expanded(
                  child: rows.isEmpty
                      ? const Center(
                          child: Text(
                            '本组无命中',
                            style: TextStyle(
                              fontSize: FontSize.secondaryNumber,
                              color: AppColors.textFaint,
                            ),
                          ),
                        )
                      : ListView.separated(
                          // 与八档局同款间距：卡片自身无 margin，靠 separated 分隔
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 9),
                          itemBuilder: (context, index) => BandHitCard(
                            hit: rows[index],
                            index: index,
                            onTap: () => widget.onSelect(rows[index].symbol),
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '破势 · 主线突破',
            style: TextStyle(
              fontSize: FontSize.screenTitle,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '与八档局共用扫描结果 · 每只股只归最高一组',
            style: mono(size: FontSize.legend, color: AppColors.textDim),
          ),
        ],
      ),
    );
  }

  Widget _stageTabs(Map<int, List<BandHit>> grouped) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var stage = 2; stage <= breakoutMainLines.length; stage++)
            _StageChip(
              label: breakoutStageLabel(stage),
              count: (grouped[stage] ?? const []).length,
              active: _stage == stage,
              onTap: () => setState(() => _stage = stage),
            ),
        ],
      ),
    );
  }
}

class _StageChip extends StatelessWidget {
  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  const _StageChip({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: active ? AppColors.accent : AppColors.hudPanel,
          border: Border.all(
            color: active ? AppColors.accent : AppColors.hudBorder,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$label%',
              style: mono(
                size: FontSize.legend,
                color: active ? const Color(0xFF050914) : AppColors.textMuted,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              '$count',
              style: mono(
                size: FontSize.legend,
                color: active ? const Color(0xFF050914) : AppColors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
