/// 八档局命中卡（唯一的命中展示形式，表格版已移除）。
/// 一条命中一张卡：名称/代码/涨幅 → 波段进度条 → 波段信息 → 形态标记。
library;

import 'package:flutter/material.dart';

import '../../logic/band_scanner.dart';
import '../../theme/app_theme.dart';
import '../../theme/hud.dart';

class BandHitCard extends StatelessWidget {
  final BandHit hit;

  /// 列表里的序号，第一张给发光
  final int index;
  final VoidCallback onTap;

  const BandHitCard({
    super.key,
    required this.hit,
    required this.index,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return HudPanel(
      radius: 12,
      tint: hit.limitUp ? AppColors.rise : null,
      glow: index == 0,
      padding: const EdgeInsets.fromLTRB(13, 12, 13, 13),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // 左侧整组用 Expanded 吃掉剩余空间，涨幅才会真正贴右。
              // 不能写成 Flexible(名称) + Spacer：两者都是 flex 1，
              // 空间被五五分，名称短的时候 Flexible 用不完的那截会留在中间，
              // 涨幅就浮在半路上（这就是之前没右对齐的原因）。
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        hit.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: FontSize.screenTitle,
                          fontWeight: FontWeight.w700,
                          color: AppColors.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Text(
                      hit.symbol,
                      style: mono(
                          size: FontSize.tableNumber, color: AppColors.textDim),
                    ),
                    if (hit.limitUp) ...[
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppColors.rise,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          '涨停',
                          style: mono(
                            size: FontSize.badge,
                            color: const Color(0xFF050914),
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              GlowText(
                '+${hit.pct.toStringAsFixed(1)}%',
                size: 24,
                color: AppColors.rise,
                blur: 16,
              ),
            ],
          ),
          const SizedBox(height: 11),
          _progress(),
          const SizedBox(height: 10),
          Wrap(
            spacing: 14,
            runSpacing: 5,
            children: [
              _meta('波段高 ${hit.maxPct.toStringAsFixed(1)}%'),
              _meta('低点 ${_shortDate(hit.lowDate)}'),
              _meta('过线 ${_shortDate(hit.crossDate)}'),
              Text(
                '超出 +${hit.over.toStringAsFixed(1)}%',
                style: mono(
                  size: FontSize.secondaryNumber,
                  color: AppColors.warn,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (_sectorLabels.isNotEmpty) ...[
            const SizedBox(height: 7),
            _sectorLine(),
          ],
          if (hit.fromTop) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                _shapeTag('异常回落'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _meta(String text) => Text(
        text,
        style:
            mono(size: FontSize.secondaryNumber, color: AppColors.textFaint),
      );

  /// 板块小字：概念优先（最多 2 个），没有概念退回行业
  /// （对齐 MoneyGrabPanel 的板块列 concepts.slice(0,2) || industry）
  List<String> get _sectorLabels {
    final concepts = hit.concepts.where((name) => name.isNotEmpty).toList();
    if (concepts.isNotEmpty) {
      return concepts.length > 2 ? concepts.sublist(0, 2) : concepts;
    }
    return hit.industry.isEmpty ? const [] : [hit.industry];
  }

  /// 行业/概念行：热点带醒目的「热」标
  Widget _sectorLine() {
    return Row(
      children: [
        if (hit.hotSector) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.warn.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: AppColors.warn.withValues(alpha: 0.7)),
            ),
            child: Text(
              '热',
              style: mono(
                size: FontSize.badge,
                color: AppColors.warn,
                weight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 6),
        ],
        Expanded(
          child: Text(
            _sectorLabels.join(' · '),
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: FontSize.legend,
              color: hit.hotSector ? AppColors.warn : AppColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }

  /// 波段进度条：填充 = pct/maxPct，轨上两根针 = 主线与入档线（主线+10）
  Widget _progress() {
    final span = hit.maxPct <= 0 ? 1.0 : hit.maxPct;
    double at(double pct) => (pct / span).clamp(0.0, 1.0);
    final threshold = groupThreshold(hit.group);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) => SizedBox(
            height: 6,
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: AppColors.panelBorder.withValues(alpha: 0.7),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: at(hit.pct),
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      gradient: LinearGradient(
                        colors: [
                          AppColors.rise.withValues(alpha: 0.35),
                          AppColors.rise,
                        ],
                      ),
                    ),
                  ),
                ),
                _needle(box.maxWidth * at(threshold), AppColors.yellowLine),
                _needle(
                  box.maxWidth * at(groupEntryLine(hit.group)),
                  AppColors.text.withValues(alpha: 0.8),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            Text(
              hit.low90.toStringAsFixed(2),
              style: mono(
                  size: FontSize.secondaryNumber, color: AppColors.textDim),
            ),
            const Spacer(),
            Text(
              hit.price.toStringAsFixed(2),
              style:
                  mono(size: FontSize.secondaryNumber, color: AppColors.text),
            ),
          ],
        ),
      ],
    );
  }

  Widget _needle(double left, Color color) => Positioned(
        left: left,
        top: -1,
        child: Container(width: 1.5, height: 8, color: color),
      );

  Widget _shapeTag(String label) => Container(
        margin: const EdgeInsets.only(right: 5),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: AppColors.hudBorder),
        ),
        child: Text(
          label,
          style: mono(size: FontSize.badge, color: AppColors.textFaint),
        ),
      );

  String _shortDate(String date) => date.length >= 10 ? date.substring(5) : date;
}
