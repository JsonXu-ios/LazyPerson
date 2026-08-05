/// 八档雷达：替换 band_scan_screen.dart 里的 _buildGroupTabs 横向 Tab。
/// 八根竖轨 = 八个档位，柱高 = 该档命中占比，选中档发光描边。
/// 新增文件：lib/ui/widgets/band_radar.dart
library;

import 'package:flutter/material.dart';

import '../../logic/band_scanner.dart' show maxGroups, groupLower;
import '../../theme/app_theme.dart';

const bandGroupNames = ['一', '二', '三', '四', '五', '六', '七', '八'];

class BandRadar extends StatelessWidget {
  /// BandScanController.groupCounts
  final Map<int, int> counts;
  final int activeGroup;
  final ValueChanged<int> onSelect;

  /// 展示层过滤后的命中总数（visibleHits.length），用于标题
  final int visibleTotal;
  final int allTotal;

  const BandRadar({
    super.key,
    required this.counts,
    required this.activeGroup,
    required this.onSelect,
    required this.visibleTotal,
    required this.allTotal,
  });

  @override
  Widget build(BuildContext context) {
    var maxCount = 1;
    for (final value in counts.values) {
      if (value > maxCount) maxCount = value;
    }
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: AppColors.hudPanel,
        border: Border.all(color: AppColors.accent.withValues(alpha: 0.16)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              // 命中数四位数时这行在 360dp 会顶出去，左侧允许被截
              Flexible(
                child: Text(
                  '档位分布 · 命中 $visibleTotal / $allTotal',
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: mono(
                      size: FontSize.legend,
                      color: AppColors.textFaint,
                      weight: FontWeight.w600,
                      letterSpacing: 1.2),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${bandGroupNames[activeGroup - 1]}档 ACTIVE',
                style: mono(
                    size: FontSize.legend,
                    color: AppColors.accent,
                    weight: FontWeight.w600,
                    letterSpacing: 1.2),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 104,
            child: Row(
              children: [
                for (var group = 1; group <= maxGroups; group++) ...[
                  Expanded(
                    child: _RadarBar(
                      name: bandGroupNames[group - 1],
                      // 档位区间 [本档下沿, 下一档下沿)，第八档没有上限
                      hint: group == maxGroups
                          ? '${groupLower[group - 1].toInt()}%+'
                          : '${groupLower[group - 1].toInt()}~'
                              '${groupLower[group].toInt()}%',
                      count: counts[group] ?? 0,
                      ratio: (counts[group] ?? 0) / maxCount,
                      active: group == activeGroup,
                      onTap: () => onSelect(group),
                    ),
                  ),
                  if (group != maxGroups) const SizedBox(width: 8),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarBar extends StatelessWidget {
  final String name;
  final String hint;
  final int count;
  final double ratio;
  final bool active;
  final VoidCallback onTap;

  const _RadarBar({
    required this.name,
    required this.hint,
    required this.count,
    required this.ratio,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final hit = count > 0;
    // 空档也留一截底座，保持八根轨的节奏（1d 稿的 0.05~0.10）
    final fill = hit ? (0.22 + 0.78 * ratio).clamp(0.0, 1.0) : 0.08;
    return Semantics(
      button: true,
      selected: active,
      label: '$name档 $hint 命中 $count',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(
          children: [
            Text(
              '$count',
              style: mono(
                size: FontSize.secondaryNumber,
                color: hit ? AppColors.accent : AppColors.textDim,
                weight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: LayoutBuilder(
                builder: (context, box) => Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: AppColors.panelBorder.withValues(alpha: 0.55),
                    border: Border.all(
                      color: active
                          ? AppColors.accent.withValues(alpha: 0.55)
                          : Colors.transparent,
                    ),
                  ),
                  alignment: Alignment.bottomCenter,
                  clipBehavior: Clip.antiAlias,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    height: box.maxHeight * fill,
                    decoration: BoxDecoration(
                      gradient: hit
                          ? LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                AppColors.accent,
                                AppColors.accent.withValues(alpha: 0.25),
                              ],
                            )
                          : null,
                      color: hit ? null : AppColors.textFaint.withValues(alpha: 0.28),
                      boxShadow: hit
                          ? [
                              BoxShadow(
                                color: AppColors.accent.withValues(alpha: 0.45),
                                blurRadius: 14,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              style: TextStyle(
                fontSize: FontSize.cardTitle,
                fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                color: hit ? AppColors.text : AppColors.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
