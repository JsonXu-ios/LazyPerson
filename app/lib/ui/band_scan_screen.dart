/// 八档局 · 档位雷达（HUD 方案 1d，稿 10）：雷达选档 → 命中列表（表格/卡片双视图）。
/// 交互对齐 frontend/src/components/MoneyGrabPanel.tsx。
library;

import 'package:flutter/material.dart';

import '../logic/band_scanner.dart';
import '../state/band_scan_controller.dart';
import '../theme/app_theme.dart';
import '../theme/hud.dart';
import 'widgets/band_hit_table.dart';
import 'widgets/band_radar.dart';

class BandScanScreen extends StatefulWidget {
  final BandScanController controller;
  final ValueChanged<String> onSelect;

  const BandScanScreen({
    super.key,
    required this.controller,
    required this.onSelect,
  });

  @override
  State<BandScanScreen> createState() => _BandScanScreenState();
}

class _BandScanScreenState extends State<BandScanScreen> {
  /// 纯展示偏好，不进 controller
  bool _tableView = true;

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

  @override
  Widget build(BuildContext context) {
    final running = controller.running;
    final hasAnyHits = controller.hits.isNotEmpty;
    final showResult = hasAnyHits || controller.status == BandScanStatus.done;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: hudBackgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _appBar(),
              _rules(),
              _buildActions(running),
              if (controller.status == BandScanStatus.failed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                  child: HudPanel(
                    radius: 10,
                    tint: AppColors.rise,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 8,
                    ),
                    child: Text(
                      '扫描失败：${controller.error ?? ''}',
                      style: const TextStyle(
                        fontSize: FontSize.body,
                        color: AppColors.rise,
                      ),
                    ),
                  ),
                ),
              if (running) _buildProgress(),
              if (showResult) ...[
                const SizedBox(height: 10),
                BandRadar(
                  counts: controller.groupCounts,
                  activeGroup: controller.activeGroup,
                  onSelect: controller.setActiveGroup,
                  visibleTotal: controller.visibleHits.length,
                  allTotal: controller.hits.length,
                ),
                _listHead(),
                Expanded(
                  child: _tableView
                      ? BandHitTable(
                          hits: controller.activeHits,
                          running: running,
                          onSelect: widget.onSelect,
                        )
                      : _buildHitCards(running),
                ),
              ] else
                Expanded(
                  child: Center(
                    child: Text(
                      '点击“开始扫描”用本地日线数据计算档位',
                      style: TextStyle(
                        fontSize: FontSize.body,
                        color: AppColors.textFaint,
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

  Widget _appBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 16, 0),
      child: Row(
        children: [
          IconButton(
            iconSize: 20,
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back, color: AppColors.textMuted),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '八档局 · 档位雷达',
                  style: TextStyle(
                    fontSize: FontSize.screenTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'SHSZ MAIN · 90D BAND SCAN',
                  style: mono(
                    size: FontSize.capsLabel,
                    color: AppColors.accent,
                    weight: FontWeight.w600,
                    letterSpacing: 2.6,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rules() {
    const bodyStyle = TextStyle(
      fontSize: FontSize.caption,
      height: 1.75,
      color: AppColors.textMuted,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(11, 8, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.hudPanel,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
        border: Border(left: BorderSide(color: AppColors.accent, width: 2)),
      ),
      child: RichText(
        text: const TextSpan(
          style: bodyStyle,
          children: [
            TextSpan(text: '沪深主板（60/00）。90 日波段（低点→高点）分档：过主线（20/50/80/…）后再站上 '),
            TextSpan(
              text: '10 个点',
              style: TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text:
                  '才入档，有效区一档 30~40%、二档 60~70%、三档 90~100%…；'
                  '刚过主线不足10点、档间过渡区不入档。'
                  '「从高处来」的两种形态（从顶部跌破已站上线、V型反弹）默认隐藏，勾选开关即可并入列表。',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(bool running) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Wrap(
              spacing: 12,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(
                  height: 34,
                  child: OutlinedButton(
                    onPressed: running ? null : controller.startScan,
                    child: Text(
                      running
                          ? '扫描中…'
                          : controller.status == BandScanStatus.done
                          ? '重新扫描'
                          : '开始扫描',
                      style: const TextStyle(fontSize: FontSize.body),
                    ),
                  ),
                ),
                _checkbox(
                  label: '总市值 > ${BandScanController.marketCapMin.toInt()} 亿',
                  value: controller.capFilter,
                  onChanged: running ? null : controller.setCapFilter,
                ),
                _checkbox(
                  label: '今日涨停',
                  value: controller.limitUpFilter,
                  onChanged: controller.setLimitUpFilter,
                ),
                _checkbox(
                  label: '含从顶部下来',
                  value: controller.showFromTop,
                  onChanged: controller.setShowFromTop,
                ),
                _checkbox(
                  label: '含V型反弹',
                  value: controller.showVShape,
                  onChanged: controller.setShowVShape,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                controller.tradeDate ?? '',
                style: mono(
                  size: FontSize.tableNumber,
                  color: AppColors.textFaint,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                controller.status == BandScanStatus.done
                    ? 'SCAN ${controller.total}'
                    : controller.minMarketCap != null
                    ? 'CAP>${controller.minMarketCap!.toInt()}亿'
                    : 'CAP ALL',
                style: mono(
                  size: FontSize.legend,
                  color: AppColors.textDim,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _checkbox({
    required String label,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    final enabled = onChanged != null;
    return GestureDetector(
      onTap: enabled ? () => onChanged(!value) : null,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 15,
            height: 15,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(3),
              color: value
                  ? (enabled ? AppColors.accent : AppColors.textFaint)
                  : Colors.transparent,
              border: Border.all(
                color: value
                    ? Colors.transparent
                    : (enabled
                          ? AppColors.hudBorderActive
                          : AppColors.hudBorder),
              ),
            ),
            child: value
                ? const Icon(Icons.check, size: 11, color: Color(0xFF050914))
                : null,
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: FontSize.body,
              color: enabled ? AppColors.textMuted : AppColors.textDim,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProgress() {
    final total = controller.total;
    final ratio = total > 0 ? controller.done / total : null;
    final text = controller.stage == 'snapshot' || total == 0
        ? '正在拉取全市场行情快照…'
        : '本地日线计算档位 ${controller.done} / $total';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HudSegmentBar(ratio: ratio),
          const SizedBox(height: 4),
          Text(
            text,
            style: mono(size: FontSize.legend, color: AppColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _listHead() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          Text(
            '${bandGroupNames[controller.activeGroup - 1]}档命中 ${controller.activeHits.length}',
            style: mono(
              size: FontSize.legend,
              color: AppColors.textFaint,
              letterSpacing: 1.2,
            ),
          ),
          const Spacer(),
          BandViewToggle(
            table: _tableView,
            onChanged: (value) => setState(() => _tableView = value),
          ),
        ],
      ),
    );
  }

  Widget _buildHitCards(bool running) {
    final rows = controller.activeHits;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          running ? '本档暂无命中（扫描中…）' : '本档无命中',
          style: const TextStyle(
            fontSize: FontSize.body,
            color: AppColors.textFaint,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _hitCard(rows[index], index),
    );
  }

  Widget _hitCard(BandHit hit, int index) {
    return HudPanel(
      radius: 12,
      tint: hit.limitUp ? AppColors.rise : null,
      glow: index == 0,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      onTap: () => widget.onSelect(hit.symbol),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  hit.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: FontSize.cardTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                hit.symbol,
                style: mono(size: FontSize.legend, color: AppColors.textDim),
              ),
              if (hit.limitUp) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 5,
                    vertical: 1,
                  ),
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
              const Spacer(),
              GlowText(
                '+${hit.pct.toStringAsFixed(1)}%',
                size: 20,
                color: AppColors.rise,
                blur: 16,
              ),
            ],
          ),
          const SizedBox(height: 9),
          _bandProgress(hit),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                '波段高 ${hit.maxPct.toStringAsFixed(1)}%',
                style: mono(
                  size: FontSize.tableNumber,
                  color: AppColors.textFaint,
                ),
              ),
              Text(
                '低点 ${_shortDate(hit.lowDate)}',
                style: mono(
                  size: FontSize.tableNumber,
                  color: AppColors.textFaint,
                ),
              ),
              Text(
                '过线 ${_shortDate(hit.crossDate)}',
                style: mono(
                  size: FontSize.tableNumber,
                  color: AppColors.textFaint,
                ),
              ),
              Text(
                '超出 +${hit.over.toStringAsFixed(1)}%',
                style: mono(
                  size: FontSize.tableNumber,
                  color: AppColors.warn,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ),
          if (hit.fromTop || hit.vShape) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                if (hit.fromTop) _shapeTag('顶部下来'),
                if (hit.vShape) _shapeTag('V型'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// 波段进度条：填充 = pct/maxPct，轨上两根针 = 主线与入档线（主线+10）
  Widget _bandProgress(BandHit hit) {
    final span = hit.maxPct <= 0 ? 1.0 : hit.maxPct;
    double at(double pct) => (pct / span).clamp(0.0, 1.0);
    final threshold = groupThreshold(hit.group);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, box) => SizedBox(
            height: 5,
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
                  box.maxWidth * at(threshold + 10),
                  AppColors.text.withValues(alpha: 0.8),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              hit.low90.toStringAsFixed(2),
              style: mono(size: FontSize.tableNumber, color: AppColors.textDim),
            ),
            const Spacer(),
            Text(
              hit.price.toStringAsFixed(2),
              style: mono(size: FontSize.tableNumber, color: AppColors.text),
            ),
          ],
        ),
      ],
    );
  }

  Widget _needle(double left, Color color) => Positioned(
    left: left,
    top: -1,
    child: Container(width: 1.5, height: 7, color: color),
  );

  Widget _shapeTag(String label) => Container(
    margin: const EdgeInsets.only(right: 4),
    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(3),
      border: Border.all(color: AppColors.hudBorder),
    ),
    child: Text(
      label,
      style: mono(size: FontSize.badge, color: AppColors.textFaint),
    ),
  );

  String _shortDate(String date) =>
      date.length >= 10 ? date.substring(5) : date;
}
