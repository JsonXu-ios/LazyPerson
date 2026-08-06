/// 八档局 · 档位雷达（HUD 方案 1d，稿 10）：雷达选档 → 命中卡片列表。
/// 筛选做成可点的开关 chip；命中只有卡片一种形式（表格版已移除）。
library;

import 'package:flutter/material.dart';

import '../logic/band_scanner.dart';
import '../state/band_scan_controller.dart';
import '../theme/app_theme.dart';
import '../theme/hud.dart';
import 'widgets/band_hit_card.dart';
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
  BandScanController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.restore();
    controller.loadSyncStatus();
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
    final showResult =
        controller.hits.isNotEmpty || controller.status == BandScanStatus.done;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: hudBackgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _appBar(),
              _actions(running),
              _syncStatus(),
              _enrichLine(),
              _filters(running),
              if (controller.status == BandScanStatus.failed) _failure(),
              if (running) _progress(),
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
                Expanded(child: _hitCards(running)),
              ] else
                Expanded(
                  child: Center(
                    child: Text(
                      '点击“开始扫描”用本地日线数据计算档位',
                      style: const TextStyle(
                        fontSize: FontSize.secondaryNumber,
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
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
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
                  overflow: TextOverflow.clip,
                  softWrap: false,
                  style: mono(
                    size: FontSize.legend,
                    color: AppColors.accent,
                    weight: FontWeight.w600,
                    letterSpacing: 2.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _actions(bool running) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          _ScanButton(
            // 补齐/补充数据期间也锁住（都会占满网络，且 startScan 此时直接返回）
            running: controller.busy,
            label: running
                ? '扫描中…'
                : controller.backfilling
                ? '补齐中…'
                : controller.enriching
                ? '补数据中…'
                : controller.status == BandScanStatus.done
                ? '重新扫描'
                : '开始扫描',
            onPressed: controller.startScan,
          ),
          const Spacer(),
          // 补齐提示可能挺长，右侧整列可压缩（窄屏 360dp 不顶出去）
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  controller.tradeDate ?? '',
                  style: mono(
                    size: FontSize.secondaryNumber,
                    color: AppColors.textFaint,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  controller.status == BandScanStatus.done
                      ? 'SCAN ${controller.total}$_scanCost'
                      : controller.minMarketCap != null
                      ? 'CAP>${controller.minMarketCap!.toInt()}亿'
                      : 'CAP ALL',
                  overflow: TextOverflow.ellipsis,
                  style: mono(
                    size: FontSize.legend,
                    color: AppColors.textDim,
                    letterSpacing: 0.8,
                  ),
                ),
                if (controller.skippedNoData > 0 ||
                    controller.backfilling ||
                    controller.backfillNote != null) ...[
                  const SizedBox(height: 2),
                  _backfillLine(running),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 扫描耗时（纯本地扫描后是秒级，值得显示出来）
  String get _scanCost {
    final millis = controller.scanMillis;
    if (millis == null) return '';
    return millis < 1000
        ? ' · ${millis}ms'
        : ' · ${(millis / 1000).toStringAsFixed(1)}s';
  }

  /// 「补充数据 N 只」：扫描只读缓存，缺的标记在这里显式补。
  /// 这是本页唯一会发大量网络请求的动作，必须用户点了才跑。
  Widget _enrichLine() {
    if (controller.status != BandScanStatus.done && !controller.enriching) {
      return const SizedBox.shrink();
    }
    if (controller.enriching) {
      final total = controller.enrichTotal;
      final ratio = total > 0 ? controller.enrichDone / total : null;
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HudSegmentBar(ratio: ratio),
            const SizedBox(height: 5),
            Text(
              '补充基本面/LON 数据 ${controller.enrichDone}/$total…',
              style: mono(
                size: FontSize.secondaryNumber,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }
    final unknown = controller.unknownMarkCount;
    if (unknown == 0) {
      final note = controller.enrichNote;
      if (note == null) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Text(
          note,
          overflow: TextOverflow.ellipsis,
          style: mono(size: FontSize.legend, color: AppColors.accent),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.enrichNote ?? '分红/净利润/估市值/LON 未补充（扫描不联网取数）',
              overflow: TextOverflow.ellipsis,
              style: mono(size: FontSize.legend, color: AppColors.warn),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: controller.busy ? null : controller.enrichMarks,
            behavior: HitTestBehavior.opaque,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: AppColors.hudFillActive,
                border: Border.all(color: AppColors.hudBorderActive),
              ),
              child: Text(
                '补充数据 $unknown 只',
                style: mono(
                  size: FontSize.legend,
                  color: AppColors.accent,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 本地日K缺失提示 → 可点的「补齐」按钮（补齐中显示进度，完成后给重扫提示）
  Widget _backfillLine(bool running) {
    if (controller.backfilling) {
      return Text(
        '补齐中 ${controller.backfillDone}/${controller.backfillTotal}',
        overflow: TextOverflow.ellipsis,
        style: mono(
          size: FontSize.legend,
          color: AppColors.accent,
          letterSpacing: 0.4,
        ),
      );
    }
    if (controller.skippedNoData == 0) {
      return Text(
        controller.backfillNote ?? '',
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.end,
        style: mono(
          size: FontSize.legend,
          color: AppColors.accent,
          letterSpacing: 0.4,
        ),
      );
    }
    final canBackfill = !running && controller.skippedSymbols.isNotEmpty;
    return GestureDetector(
      onTap: canBackfill ? controller.backfillMissing : null,
      behavior: HitTestBehavior.opaque,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              '本地日K缺失 跳过${controller.skippedNoData}只',
              overflow: TextOverflow.ellipsis,
              style: mono(
                size: FontSize.legend,
                color: AppColors.warn,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (canBackfill) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: AppColors.hudFillActive,
                border: Border.all(color: AppColors.hudBorderActive),
              ),
              child: Text(
                '补齐',
                style: mono(
                  size: FontSize.legend,
                  color: AppColors.accent,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 同步状态行：只显示本地数据同步到哪一天/未初始化警示。
  /// 数据更新在首页状态横条统一处理，且扫描本身会把快照当日bar落库，
  /// 这里不再提供手动刷新入口。
  Widget _syncStatus() {
    final String text;
    final Color color;
    if (controller.initialized == false) {
      text = '全市场数据未初始化，请回首页完成同步';
      color = AppColors.warn;
    } else if (controller.dataDate == null) {
      text = '同步状态加载中…';
      color = AppColors.textFaint;
    } else {
      final today = DateTime.now();
      final dataDay = DateTime.tryParse('${controller.dataDate}T00:00:00');
      final lagDays = dataDay == null ? 99 : today.difference(dataDay).inDays;
      text = '本地数据同步至 ${controller.dataDate}';
      color = lagDays > 3 ? AppColors.warn : AppColors.textDim;
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          Icon(
            controller.initialized == false ? Icons.warning_amber : Icons.sync,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 5),
          Expanded(
            child: Text(
              text,
              style: mono(size: FontSize.legend, color: color),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 筛选做成可点的开关 chip：整块可点、有明确的选中态，
  /// 比原来 12dp 的小勾选框好按得多。分红/净利润/估市值/LON 是
  /// 展示层过滤（命中行已带标记，切换无需重扫），默认不勾选。
  /// 标记是三态的：勾选后只显示**确定**达标的，未知的不显示，
  /// 因此这里额外提示还有多少只没补数据。
  Widget _filters(bool running) {
    final unknown = controller.unknownMarkCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _filterChips(running),
          ),
          if (controller.markFilterActive && unknown > 0) ...[
            const SizedBox(height: 6),
            Text(
              '有 $unknown 只数据未补充（未知的不计入筛选结果）',
              overflow: TextOverflow.ellipsis,
              style: mono(size: FontSize.legend, color: AppColors.warn),
            ),
          ],
        ],
      ),
    );
  }

  List<Widget> _filterChips(bool running) => [
          _FilterChip(
            label: '市值 > ${BandScanController.marketCapMin.toInt()} 亿',
            value: controller.capFilter,
            // 市值是扫描参数，扫描中改了也不生效，禁用
            onChanged: running ? null : controller.setCapFilter,
          ),
          _FilterChip(
            label: '今日涨停',
            value: controller.limitUpFilter,
            onChanged: controller.setLimitUpFilter,
          ),
          _FilterChip(
            label: '一路北上',
            value: controller.northFilter,
            onChanged: controller.setNorthFilter,
          ),
          _FilterChip(
            label: '含回落',
            value: controller.showFromTop,
            onChanged: controller.setShowFromTop,
          ),
          _FilterChip(
            label: '分红',
            value: controller.dividendFilter,
            onChanged: controller.setDividendFilter,
          ),
          _FilterChip(
            label: '净利润',
            value: controller.profitFilter,
            onChanged: controller.setProfitFilter,
          ),
          _FilterChip(
            label: '估市值',
            value: controller.revenueFilter,
            onChanged: controller.setRevenueFilter,
          ),
          _FilterChip(
            label: 'LON',
            value: controller.lonFilter,
            onChanged: controller.setLonFilter,
          ),
          // 换手/3日/5日：来自快照与本地日K，不需要补数据就能过滤
          _FilterChip(
            label: '换手>${turnoverFilterMin.toInt()}%',
            value: controller.turnoverFilter,
            onChanged: controller.setTurnoverFilter,
          ),
          _FilterChip(
            label: '3日>${chg3FilterMin.toInt()}%',
            value: controller.chg3Filter,
            onChanged: controller.setChg3Filter,
          ),
          _FilterChip(
            label: '5日>${chg5FilterMin.toInt()}%',
            value: controller.chg5Filter,
            onChanged: controller.setChg5Filter,
          ),
        ];

  Widget _failure() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: HudPanel(
        radius: 10,
        tint: AppColors.rise,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Text(
          '扫描失败：${controller.error ?? ''}',
          style: const TextStyle(
            fontSize: FontSize.secondaryNumber,
            color: AppColors.rise,
          ),
        ),
      ),
    );
  }

  Widget _progress() {
    final total = controller.total;
    final ratio = total > 0 ? controller.done / total : null;
    final text = controller.stage == 'snapshot' || total == 0
        ? '正在拉取全市场行情快照（本次扫描唯一的网络请求）…'
        : '本地日线计算档位 ${controller.done} / $total';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HudSegmentBar(ratio: ratio),
          const SizedBox(height: 5),
          Text(
            text,
            style: mono(
              size: FontSize.secondaryNumber,
              color: AppColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  Widget _listHead() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Text(
        '${bandGroupNames[controller.activeGroup - 1]}档命中 ${controller.activeHits.length}',
        style: mono(
          size: FontSize.secondaryNumber,
          color: AppColors.textFaint,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _hitCards(bool running) {
    final rows = controller.activeHits;
    if (rows.isEmpty) {
      return Center(
        child: Text(
          running ? '本档暂无命中（扫描中…）' : '本档无命中',
          style: const TextStyle(
            fontSize: FontSize.secondaryNumber,
            color: AppColors.textFaint,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 9),
      itemBuilder: (context, index) => BandHitCard(
        hit: rows[index],
        index: index,
        onTap: () => widget.onSelect(rows[index].symbol),
      ),
    );
  }
}

/// 扫描按钮：这一页的主操作，用实心 accent + 深色字，
/// 不走主题里那套弱描边样式（描边在 HUD 深底上几乎看不见）。
class _ScanButton extends StatelessWidget {
  final String label;
  final bool running;
  final VoidCallback onPressed;

  const _ScanButton({
    required this.label,
    required this.running,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 38,
      child: FilledButton.icon(
        onPressed: running ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.accent,
          foregroundColor: const Color(0xFF050914),
          disabledBackgroundColor: AppColors.accent.withValues(alpha: 0.22),
          disabledForegroundColor: AppColors.accent,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: running
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.accent,
                ),
              )
            : const Icon(Icons.radar, size: 17),
        label: Text(
          label,
          style: const TextStyle(
            fontSize: FontSize.secondaryNumber,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

/// 筛选开关：整块可点，选中态用 accent 描边 + 底色 + 勾
class _FilterChip extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _FilterChip({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final active = value && enabled;
    return GestureDetector(
      onTap: enabled ? () => onChanged!(!value) : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: active ? AppColors.hudFillActive : Colors.transparent,
          border: Border.all(
            color: active ? AppColors.hudBorderActive : AppColors.hudBorder,
          ),
          boxShadow: active
              ? [
                  BoxShadow(
                    color: AppColors.accent.withValues(alpha: 0.18),
                    blurRadius: 18,
                    spreadRadius: -4,
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              value ? Icons.check_circle : Icons.circle_outlined,
              size: 16,
              color: !enabled
                  ? AppColors.textDim
                  : value
                  ? AppColors.accent
                  : AppColors.textFaint,
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                fontSize: FontSize.secondaryNumber,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: !enabled
                    ? AppColors.textDim
                    : active
                    ? AppColors.text
                    : AppColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
