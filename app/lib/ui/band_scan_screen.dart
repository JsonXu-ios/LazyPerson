/// 八档局 · 档位雷达（HUD 方案 1d，稿 10）：雷达选档 → 命中卡片列表。
/// 筛选做成可点的开关 chip；命中只有卡片一种形式（表格版已移除）。
library;

import 'package:flutter/material.dart';

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
              _rules(),
              _actions(running),
              _syncStatus(running),
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
      padding: const EdgeInsets.fromLTRB(6, 6, 16, 0),
      child: Row(
        children: [
          IconButton(
            iconSize: 22,
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

  Widget _rules() {
    const bodyStyle = TextStyle(
      fontSize: FontSize.secondaryNumber,
      height: 1.75,
      color: AppColors.textMuted,
    );
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.fromLTRB(12, 9, 13, 9),
      decoration: BoxDecoration(
        color: AppColors.hudPanel,
        borderRadius: const BorderRadius.only(
          topRight: Radius.circular(8),
          bottomRight: Radius.circular(8),
        ),
        border: const Border(
          left: BorderSide(color: AppColors.accent, width: 2),
        ),
      ),
      child: RichText(
        text: const TextSpan(
          style: bodyStyle,
          children: [
            TextSpan(
              text: '沪深主板（60/00）。90 日波段从低点起算：一档需站上 ',
            ),
            TextSpan(
              text: '30% 确认',
              style: TextStyle(
                color: AppColors.accent,
                fontWeight: FontWeight.w700,
              ),
            ),
            TextSpan(
              text: '（有效区 30~40%），40 是奇点；二档及以上过主线即入'
                  '（50~70%、80~100%…）。跌破曾站上的主线默认隐藏，收回自动恢复。',
            ),
          ],
        ),
      ),
    );
  }

  Widget _actions(bool running) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          _ScanButton(
            running: running,
            label: running
                ? '扫描中…'
                : controller.status == BandScanStatus.done
                    ? '重新扫描'
                    : '开始扫描',
            onPressed: controller.startScan,
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                controller.tradeDate ?? '',
                style: mono(
                    size: FontSize.secondaryNumber,
                    color: AppColors.textFaint),
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
              if (controller.skippedNoData > 0) ...[
                const SizedBox(height: 2),
                Text(
                  '本地日K缺失 跳过${controller.skippedNoData}只',
                  style: mono(
                    size: FontSize.legend,
                    color: AppColors.warn,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  /// 同步状态行：本地数据同步到哪一天 + 手动刷新全A股（每日增量）
  Widget _syncStatus(bool running) {
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
      final lagDays =
          dataDay == null ? 99 : today.difference(dataDay).inDays;
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
          GestureDetector(
            onTap: (running || controller.refreshing)
                ? null
                : controller.refreshData,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: controller.refreshing
                      ? AppColors.textFaint
                      : AppColors.accent.withValues(alpha: 0.6),
                ),
              ),
              child: Text(
                controller.refreshing ? '刷新中…' : '刷新数据',
                style: mono(
                  size: FontSize.legend,
                  color: controller.refreshing
                      ? AppColors.textFaint
                      : AppColors.accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 四个筛选做成可点的开关 chip：整块可点、有明确的选中态，
  /// 比原来 12dp 的小勾选框好按得多
  Widget _filters(bool running) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
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
            label: '含跌破主线',
            value: controller.showFromTop,
            onChanged: controller.setShowFromTop,
          ),
        ],
      ),
    );
  }

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
        ? '正在拉取全市场行情快照…'
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
                size: FontSize.secondaryNumber, color: AppColors.textMuted),
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
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
