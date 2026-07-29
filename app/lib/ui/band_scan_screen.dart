/// 八档局 · A股档位扫描页面，交互对齐 frontend/src/components/MoneyGrabPanel.tsx。
library;

import 'package:flutter/material.dart';

import '../logic/band_scanner.dart';
import '../state/band_scan_controller.dart';
import '../theme/app_theme.dart';

const _groupNames = ['一', '二', '三', '四', '五', '六', '七', '八'];

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
      appBar: AppBar(
        title: const Text('八档局 · A股档位扫描',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
      ),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: Text(
                '沪深主板（60/00）。90 日波段（低点→高点）分档：过主线（20/50/80/…）后再站上 10 个点才入档，'
                '有效区一档 30~40%、二档 60~70%、三档 90~100%…；'
                '刚过主线不足10点、档间过渡区、从顶部跌破已站上线的都不要。',
                style: TextStyle(fontSize: 10, color: AppColors.textFaint),
              ),
            ),
            _buildActions(running),
            if (controller.status == BandScanStatus.failed)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text('扫描失败：${controller.error ?? ''}',
                    style:
                        const TextStyle(fontSize: 11, color: AppColors.rise)),
              ),
            if (running) _buildProgress(),
            if (showResult) _buildGroupTabs(),
            if (showResult) _buildTableHeader(),
            if (showResult)
              Expanded(child: _buildRows(running))
            else
              const Expanded(
                child: Center(
                  child: Text('点击“开始扫描”用本地日线数据计算档位',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textFaint)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions(bool running) {
    final meta = _metaText();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: 10,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            height: 30,
            child: OutlinedButton(
              onPressed: running ? null : controller.startScan,
              child: Text(
                running
                    ? '扫描中…'
                    : controller.status == BandScanStatus.done
                        ? '重新扫描'
                        : '开始扫描',
                style: const TextStyle(fontSize: 12),
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
          if (meta.isNotEmpty)
            Text(meta,
                style:
                    const TextStyle(fontSize: 10, color: AppColors.textFaint)),
        ],
      ),
    );
  }

  String _metaText() {
    if (controller.status != BandScanStatus.done && !controller.running) {
      return '';
    }
    final visible = controller.visibleHits.length;
    final all = controller.hits.length;
    final buffer = StringBuffer()
      ..write('${controller.tradeDate ?? ''} · 命中 $visible');
    if (controller.limitUpFilter) buffer.write('（涨停）/ 全部 $all');
    buffer.write(controller.status == BandScanStatus.done
        ? ' · 扫描 ${controller.total}'
        : '（边扫边出）');
    buffer.write(controller.minMarketCap != null
        ? ' · 市值>${controller.minMarketCap!.toInt()}亿'
        : ' · 未过滤市值');
    return buffer.toString();
  }

  Widget _checkbox({
    required String label,
    required bool value,
    required ValueChanged<bool>? onChanged,
  }) {
    return GestureDetector(
      onTap: onChanged == null ? null : () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            value ? Icons.check_box : Icons.check_box_outline_blank,
            size: 15,
            color: onChanged == null
                ? AppColors.textFaint
                : (value ? AppColors.accent : AppColors.textMuted),
          ),
          const SizedBox(width: 3),
          Text(label,
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
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
      padding: const EdgeInsets.fromLTRB(12, 2, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: ratio,
            minHeight: 3,
            backgroundColor: AppColors.grid,
            color: AppColors.warn,
          ),
          const SizedBox(height: 3),
          Text(text,
              style:
                  const TextStyle(fontSize: 10, color: AppColors.textMuted)),
        ],
      ),
    );
  }

  Widget _buildGroupTabs() {
    final counts = controller.groupCounts;
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        children: [
          for (var group = 1; group <= maxGroups; group++)
            Padding(
              padding: const EdgeInsets.only(right: 6, top: 2, bottom: 2),
              child: GestureDetector(
                onTap: () => controller.setActiveGroup(group),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: controller.activeGroup == group
                        ? AppColors.panelBorder
                        : AppColors.panel,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: controller.activeGroup == group
                          ? AppColors.accent
                          : AppColors.panelBorder,
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '${_groupNames[group - 1]}档 '
                        '${(groupThreshold(group) + 10).toInt()}~${(groupThreshold(group) + 20).toInt()}%',
                        style: TextStyle(
                            fontSize: 11,
                            color: controller.activeGroup == group
                                ? AppColors.text
                                : AppColors.textMuted),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: (counts[group] ?? 0) > 0
                              ? AppColors.accent.withValues(alpha: 0.2)
                              : AppColors.grid,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Text('${counts[group] ?? 0}',
                            style: const TextStyle(
                                fontSize: 9, color: AppColors.text)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static const _columns = [
    ('代码', 52.0),
    ('名称', 64.0),
    ('最新价', 52.0),
    ('90日低点', 56.0),
    ('涨幅', 48.0),
    ('波段高', 48.0),
    ('低点日', 46.0),
    ('过线日', 46.0),
    ('超出', 46.0),
  ];

  Widget _buildTableHeader() {
    return Container(
      color: AppColors.panel,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: _rowLayout([
        for (final (label, _) in _columns)
          Text(label,
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textMuted)),
      ]),
    );
  }

  Widget _rowLayout(List<Widget> cells) {
    assert(cells.length == _columns.length);
    return Row(
      children: [
        const SizedBox(width: 8),
        for (var index = 0; index < cells.length; index++)
          index == 1
              ? Expanded(child: cells[index])
              : SizedBox(width: _columns[index].$2, child: cells[index]),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildRows(bool running) {
    final rows = controller.activeHits;
    if (rows.isEmpty) {
      return Center(
        child: Text(running ? '本档暂无命中（扫描中…）' : '本档无命中',
            style:
                const TextStyle(fontSize: 12, color: AppColors.textFaint)),
      );
    }
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, color: AppColors.grid),
      itemBuilder: (context, index) {
        final hit = rows[index];
        const cellStyle = TextStyle(fontSize: 10, color: AppColors.text);
        return InkWell(
          onTap: () => widget.onSelect(hit.symbol),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: _rowLayout([
              Text(hit.symbol, style: cellStyle),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(hit.name,
                        style: cellStyle, overflow: TextOverflow.ellipsis),
                  ),
                  if (hit.limitUp)
                    const Padding(
                      padding: EdgeInsets.only(left: 2),
                      child: Text('涨停',
                          style:
                              TextStyle(fontSize: 8, color: AppColors.rise)),
                    ),
                ],
              ),
              Text(hit.price.toStringAsFixed(2), style: cellStyle),
              Text(hit.low90.toStringAsFixed(2), style: cellStyle),
              Text('${hit.pct.toStringAsFixed(1)}%',
                  style: const TextStyle(
                      fontSize: 10,
                      color: AppColors.rise,
                      fontWeight: FontWeight.w600)),
              Text('${hit.maxPct.toStringAsFixed(1)}%', style: cellStyle),
              Text(_shortDate(hit.lowDate), style: cellStyle),
              Text(_shortDate(hit.crossDate), style: cellStyle),
              Text('+${hit.over.toStringAsFixed(1)}%',
                  style:
                      const TextStyle(fontSize: 10, color: AppColors.warn)),
            ]),
          ),
        );
      },
    );
  }

  String _shortDate(String date) => date.length >= 10 ? date.substring(5) : date;
}
