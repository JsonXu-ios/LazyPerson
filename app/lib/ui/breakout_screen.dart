/// 破势：两个视角，共用八档局那一次扫描结果（BandScanController.hits）。
/// - 主线突破：按已突破的最高主线（20/50/80/110/…）分组，每只股只归最高一组。
/// - 蓄势待发：刚刚站上某条主线、还没走远（超出 ≤5 个点，突破还热乎）。
/// - 零帧起手：从高处（至少 +50%）一路摔回 90 日低点的。**它有自己的一次扫描**
///   （ZeroBaseController），与八档局完全无关——八档局只收 pct≥20%，这批地板股
///   永远进不去它的结果。
/// 卡片额外显示行业/题材（八档局不显示，走 BandHitCard 的可选参数）。
library;

import 'package:flutter/material.dart';

import '../data/sector_service.dart';
import '../logic/band_scanner.dart';
import '../models/models.dart';
import '../state/band_scan_controller.dart';
import '../state/zero_base_controller.dart';
import '../theme/app_theme.dart';
import '../theme/hud.dart';
import 'widgets/band_hit_card.dart';

/// 破势的三个视角
enum BreakoutView { broken, buildup, zeroBase }

String breakoutViewLabel(BreakoutView view) => switch (view) {
      BreakoutView.broken => '主线突破',
      BreakoutView.buildup => '蓄势待发',
      BreakoutView.zeroBase => '零帧起手',
    };

class BreakoutScreen extends StatefulWidget {
  final BandScanController controller;

  /// 零帧起手自己的扫描（与八档局互不相干）
  final ZeroBaseController zeroBase;
  final SectorService sectors;
  final ValueChanged<String> onSelect;

  const BreakoutScreen({
    super.key,
    required this.controller,
    required this.zeroBase,
    required this.sectors,
    required this.onSelect,
  });

  @override
  State<BreakoutScreen> createState() => _BreakoutScreenState();
}

class _BreakoutScreenState extends State<BreakoutScreen> {
  BreakoutView _view = BreakoutView.broken;

  /// 默认看「20→50」组（站上50主线的那批）
  int _stage = 2;

  /// 蓄势待发默认看刚过 50 线的那批
  double _line = 50;

  /// 零帧起手默认看"曾站上 50 主线"再摔回来的那批
  int _peakStage = 2;

  /// 行业/题材：只给当前这一屏的股票补，按天缓存，切组时增量补
  final Map<String, StockSectors> _sectors = {};
  bool _loadingSectors = false;
  int _sectorRunId = 0;

  BandScanController get controller => widget.controller;

  ZeroBaseController get zeroBase => widget.zeroBase;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    zeroBase.addListener(_onChanged);
    controller.restore();
    zeroBase.restore();
  }

  @override
  void dispose() {
    _sectorRunId++; // 页面走了，在跑的补板块别再回写
    controller.removeListener(_onChanged);
    zeroBase.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 主线突破：只看真正完成过一次主线突破的（站上50及以上，stage≥2）
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

  /// 蓄势待发：按"刚站上哪条主线"分组，同组里刚过线的排前面
  Map<double, List<BandHit>> get _byLine {
    final grouped = <double, List<BandHit>>{};
    for (final hit in controller.visibleHits) {
      final line = buildupLine(hit.pct);
      if (line == null) continue;
      grouped.putIfAbsent(line, () => []).add(hit);
    }
    for (final list in grouped.values) {
      list.sort((a, b) => a.pct.compareTo(b.pct)); // 越贴近主线越靠前
    }
    return grouped;
  }

  /// 零帧起手：分组在 ZeroBaseController 里（走它自己那份扫描结果）
  Map<int, List<BandHit>> get _byPeak => zeroBase.byPeak;

  List<BandHit> get _rows => switch (_view) {
        BreakoutView.broken => _byStage[_stage] ?? const <BandHit>[],
        BreakoutView.buildup => _byLine[_line] ?? const <BandHit>[],
        BreakoutView.zeroBase => _byPeak[_peakStage] ?? const <BandHit>[],
      };

  /// 还没有结果可看（各自的扫描都没跑过）
  bool get _needsScan => _view == BreakoutView.zeroBase
      ? zeroBase.hits.isEmpty && zeroBase.status != ZeroBaseStatus.running
      : controller.hits.isEmpty;

  /// 给当前这组里还没板块信息的股票补一次（当日缓存命中的不发请求）
  Future<void> _loadSectors(List<BandHit> rows) async {
    final missing = [
      for (final hit in rows)
        if (!_sectors.containsKey(hit.symbol)) hit.symbol,
    ];
    if (missing.isEmpty || _loadingSectors) return;
    final runId = ++_sectorRunId;
    setState(() => _loadingSectors = true);
    try {
      await widget.sectors.sectorsOfMany(
        missing,
        shouldStop: () => runId != _sectorRunId,
        onEach: (symbol, marks) {
          if (runId != _sectorRunId || marks == null || !mounted) return;
          setState(() => _sectors[symbol] = marks);
        },
      );
    } catch (_) {
      // 板块取不到就不显示，不影响主列表
    }
    if (mounted && runId == _sectorRunId) {
      setState(() => _loadingSectors = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    // 列表构建完再补板块，避免在 build 里同步 setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && rows.isNotEmpty) _loadSectors(rows);
    });
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: hudBackgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              _viewTabs(),
              if (_view == BreakoutView.zeroBase) ...[
                _zeroBaseActions(),
                _zeroBaseFilters(),
              ],
              _groupChips(),
              if (_needsScan)
                Expanded(
                  child: Center(
                    child: Text(
                      _view == BreakoutView.zeroBase
                          ? '点上面的「开始扫描」找地板股'
                          : '请先到「八档局」执行一次扫描',
                      style: const TextStyle(
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
                          // 卡片自身无 margin，靠 separated 拉开间距
                          padding: const EdgeInsets.fromLTRB(
                              16, 6, 16, bottomNavSafePadding),
                          itemCount: rows.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 14),
                          itemBuilder: (context, index) => BandHitCard(
                            hit: rows[index],
                            index: index,
                            sectors: _sectors[rows[index].symbol],
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
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '破势 · ${breakoutViewLabel(_view)}',
                  style: const TextStyle(
                    fontSize: FontSize.screenTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  switch (_view) {
                    BreakoutView.broken => '与八档局共用扫描结果 · 每只股只归最高一组',
                    BreakoutView.buildup =>
                      '刚站上主线、超出 ≤${buildupMaxOver.toInt()}%（突破还热乎）',
                    BreakoutView.zeroBase =>
                      '独立扫描 · 至少从 +${zeroBaseMinPeak.toInt()}% 摔回 90 日低点'
                          '（≤${zeroBaseMaxPct.toInt()}%）',
                  },
                  style: mono(size: FontSize.legend, color: AppColors.textDim),
                ),
              ],
            ),
          ),
          if (_loadingSectors || zeroBase.running || zeroBase.enriching)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: AppColors.accent),
            ),
        ],
      ),
    );
  }

  /// 顶部三个视角的 tab
  Widget _viewTabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          for (final view in BreakoutView.values)
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _view = view),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        width: _view == view ? 2 : 1,
                        color: _view == view
                            ? AppColors.accent
                            : AppColors.hudBorder,
                      ),
                    ),
                  ),
                  child: Text(
                    breakoutViewLabel(view),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: FontSize.secondaryNumber,
                      fontWeight: FontWeight.w700,
                      color:
                          _view == view ? AppColors.accent : AppColors.textDim,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 零帧起手自己的扫描入口：进度、耗时、命中数都在这一行里
  Widget _zeroBaseActions() {
    final running = zeroBase.running;
    final label = running
        ? (zeroBase.stage == 'snapshot'
            ? '拉行情快照…'
            : '扫描中 ${zeroBase.done}/${zeroBase.total}')
        : zeroBase.enriching
            ? '补基本面 ${zeroBase.enrichDone}/${zeroBase.enrichTotal}'
            : zeroBase.status == ZeroBaseStatus.done
                ? '重新扫描'
                : '开始扫描';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: zeroBase.busy ? null : zeroBase.startScan,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(7),
                    color: zeroBase.busy ? AppColors.hudPanel : AppColors.accent,
                    border: Border.all(
                      color:
                          zeroBase.busy ? AppColors.hudBorder : AppColors.accent,
                    ),
                  ),
                  child: Text(
                    label,
                    style: mono(
                      size: FontSize.secondaryNumber,
                      color: zeroBase.busy
                          ? AppColors.textMuted
                          : const Color(0xFF050914),
                      weight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const Spacer(),
              Flexible(
                child: Text(
                  zeroBase.status == ZeroBaseStatus.done
                      ? '命中 ${zeroBase.hits.length}$_zeroBaseCost'
                      : zeroBase.tradeDate ?? '',
                  overflow: TextOverflow.ellipsis,
                  style:
                      mono(size: FontSize.legend, color: AppColors.textFaint),
                ),
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 6),
            HudSegmentBar(
              ratio: zeroBase.total > 0 ? zeroBase.done / zeroBase.total : null,
            ),
          ],
          if (zeroBase.status == ZeroBaseStatus.failed) ...[
            const SizedBox(height: 6),
            Text(
              zeroBase.error ?? '扫描失败',
              style: mono(size: FontSize.legend, color: AppColors.warn),
            ),
          ],
          // 基本面没补全时给个手动重试入口（与八档局一致）
          if (!zeroBase.busy &&
              zeroBase.status == ZeroBaseStatus.done &&
              zeroBase.unknownMarkCount > 0) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: zeroBase.enrichMarks,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  const Icon(Icons.refresh, size: 13, color: AppColors.accent),
                  const SizedBox(width: 5),
                  Flexible(
                    child: Text(
                      '${zeroBase.unknownMarkCount} 只基本面未补充，点这里补充',
                      overflow: TextOverflow.ellipsis,
                      style: mono(
                        size: FontSize.legend,
                        color: AppColors.accent,
                        weight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  String get _zeroBaseCost {
    final millis = zeroBase.scanMillis;
    if (millis == null) return '';
    return millis < 1000
        ? ' · ${millis}ms'
        : ' · ${(millis / 1000).toStringAsFixed(1)}s';
  }

  /// 零帧起手的筛选：分红 / 净利润 / 估市值 / 换手（切换即时生效）
  Widget _zeroBaseFilters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _FilterChip(
            label: '分红',
            active: zeroBase.dividendFilter,
            onTap: () => zeroBase.setDividendFilter(!zeroBase.dividendFilter),
          ),
          _FilterChip(
            label: '净利润',
            active: zeroBase.profitFilter,
            onTap: () => zeroBase.setProfitFilter(!zeroBase.profitFilter),
          ),
          _FilterChip(
            label: '估市值',
            active: zeroBase.revenueFilter,
            onTap: () => zeroBase.setRevenueFilter(!zeroBase.revenueFilter),
          ),
          _FilterChip(
            label: '换手>${turnoverFilterMin.toInt()}%',
            active: zeroBase.turnoverFilter,
            onTap: () => zeroBase.setTurnoverFilter(!zeroBase.turnoverFilter),
          ),
        ],
      ),
    );
  }

  /// 组切换：主线突破按"突破到哪条线"，蓄势待发按"刚站上哪条线"，
  /// 零帧起手按"曾站上过哪条线"（从多高摔下来的）
  Widget _groupChips() {
    final byStage = _view == BreakoutView.broken
        ? _byStage
        : const <int, List<BandHit>>{};
    final byLine = _view == BreakoutView.buildup
        ? _byLine
        : const <double, List<BandHit>>{};
    final byPeak = _view == BreakoutView.zeroBase
        ? _byPeak
        : const <int, List<BandHit>>{};
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (_view == BreakoutView.broken)
            for (var stage = 2; stage <= breakoutMainLines.length; stage++)
              _StageChip(
                label: '${breakoutStageLabel(stage)}%',
                count: (byStage[stage] ?? const []).length,
                active: _stage == stage,
                onTap: () => setState(() => _stage = stage),
              ),
          if (_view == BreakoutView.buildup)
            for (final line in breakoutMainLines)
              _StageChip(
                label: '刚过 ${line.toInt()}%',
                count: (byLine[line] ?? const []).length,
                active: _line == line,
                onTap: () => setState(() => _line = line),
              ),
          if (_view == BreakoutView.zeroBase)
            for (var stage = 1; stage <= breakoutMainLines.length; stage++)
              _StageChip(
                label: '曾过 ${breakoutMainLines[stage - 1].toInt()}%',
                count: (byPeak[stage] ?? const []).length,
                active: _peakStage == stage,
                onTap: () => setState(() => _peakStage = stage),
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
              label,
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


/// 筛选开关 chip（零帧起手用）
class _FilterChip extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
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
        child: Text(
          label,
          style: mono(
            size: FontSize.legend,
            color: active ? const Color(0xFF050914) : AppColors.textMuted,
            weight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
