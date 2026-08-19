/// 八档局命中卡（唯一的命中展示形式，表格版已移除）。
/// 一条命中一张卡：名称/代码/涨幅 → 波段进度条 → 波段信息 → 形态标记。
library;

import 'package:flutter/material.dart';

import '../../logic/band_scanner.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/hud.dart';

class BandHitCard extends StatelessWidget {
  final BandHit hit;

  /// 列表里的序号，第一张给发光
  final int index;
  final VoidCallback onTap;

  /// 行业/题材（破势页会传；八档局不显示板块，传 null 即整行不占位）
  final StockSectors? sectors;

  const BandHitCard({
    super.key,
    required this.hit,
    required this.index,
    required this.onTap,
    this.sectors,
  });

  /// 零帧起手：group 0（贴着 90 日低点那批），标签与配色都另一套
  bool get zeroBase => hit.group == 0;

  /// 从波段高点回到现价的跌幅%（零帧起手用）：高点 100 → 现价 pct
  double get _dropFromPeak {
    final peak = 1 + hit.maxPct / 100;
    if (peak <= 0) return 0;
    return (1 - (1 + hit.pct / 100) / peak) * 100;
  }

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
                zeroBase
                    ? '-${_dropFromPeak.toStringAsFixed(1)}%'
                    : '+${hit.pct.toStringAsFixed(1)}%',
                size: 24,
                color: zeroBase ? AppColors.fall : AppColors.rise,
                blur: 16,
              ),
            ],
          ),
          if (sectors != null && !sectors!.isEmpty) ...[
            const SizedBox(height: 7),
            _sectorLine(sectors!),
          ],
          const SizedBox(height: 11),
          _progress(),
          const SizedBox(height: 10),
          // 零帧起手（group 0）没有"过线/超出"，crossDate 复用成高点日期
          Wrap(
            spacing: 14,
            runSpacing: 5,
            children: zeroBase
                ? [
                    _meta('高点 ${_shortDate(hit.crossDate)}'),
                    _meta('低点 ${_shortDate(hit.lowDate)}'),
                    Text(
                      '自高点 -${_dropFromPeak.toStringAsFixed(1)}%',
                      style: mono(
                        size: FontSize.secondaryNumber,
                        color: AppColors.fall,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ]
                : [
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
          const SizedBox(height: 6),
          Wrap(
            spacing: 14,
            runSpacing: 5,
            children: [
              _meta('换手 ${_pct(hit.turnover)}'),
              _meta('3日 ${_signedPct(hit.chg3)}'),
              _meta('5日 ${_signedPct(hit.chg5)}'),
            ],
          ),
          if (hit.fromTop || !hit.marksKnown) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 5,
              runSpacing: 5,
              children: [
                if (hit.fromTop)
                  Tooltip(
                    message: '曾进过更高档、现已回落（重新站上该档下沿即恢复）',
                    child: _shapeTag('回落'),
                  ),
                if (!hit.marksKnown)
                  Tooltip(
                    message: '基本面/LON 标记未补充：扫描不联网取数，'
                        '点页面上的「补充数据」按钮才会拉',
                    child: _shapeTag('数据未补充'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 板块行：行业 + 前两个概念；命中今日热点的概念优先排前面并高亮
  Widget _sectorLine(StockSectors marks) {
    final hot = marks.hotConcepts;
    final rest = [
      for (final name in marks.concepts)
        if (!hot.contains(name)) name,
    ];
    final themes = [...hot, ...rest].take(3).toList();
    return Row(
      children: [
        if (marks.industry.isNotEmpty) ...[
          Text(
            marks.industry,
            style: mono(
              size: FontSize.legend,
              color: AppColors.accent,
              weight: FontWeight.w600,
            ),
          ),
          if (themes.isNotEmpty)
            Text('  ·  ',
                style: mono(size: FontSize.legend, color: AppColors.textFaint)),
        ],
        Expanded(
          child: Text(
            themes.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mono(
              size: FontSize.legend,
              color: marks.hot ? AppColors.warn : AppColors.textDim,
            ),
          ),
        ),
      ],
    );
  }

  Widget _meta(String text) => Text(
        text,
        style:
            mono(size: FontSize.secondaryNumber, color: AppColors.textFaint),
      );

  /// 波段进度条：填充 = pct/maxPct，轨上一根针 = 本档下沿（入档线，
  /// 一档 20%、二档 40%、三档 70%…）。
  Widget _progress() {
    final span = hit.maxPct <= 0 ? 1.0 : hit.maxPct;
    double at(double pct) => (pct / span).clamp(0.0, 1.0);
    // 零帧起手没有入档线，针指到波段高点（看它是从多高摔下来的）
    final threshold = zeroBase ? hit.maxPct : groupThreshold(hit.group);
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

  /// 数据缺失（快照没给换手率 / 日K不够算 N 日涨幅）显示 '-'
  String _pct(double? value) =>
      value == null ? '-' : '${value.toStringAsFixed(1)}%';

  String _signedPct(double? value) => value == null
      ? '-'
      : '${value >= 0 ? '+' : ''}${value.toStringAsFixed(1)}%';
}
