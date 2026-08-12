/// 自选资产页（底部导航左 tab，App 默认落地页）。
/// 稿 11 的自选浮层升级成整页：搜索添加 → 数据状态条 → 排序 → 列表
/// （行内带热点 tag 与「资产信息」按钮）→ 数据维护（补齐 / 强制全量刷新）。
/// 点某一行进入个股详情页（K 线 + 指标）。
library;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/home_controller.dart';
import '../theme/app_theme.dart';
import '../theme/hud.dart';
import '../utils/format.dart';
import 'widgets/sparkline.dart';
import 'widgets/summary_sheet.dart';

enum _SortKey { custom, pct, amount, price }

const _sortLabels = <(_SortKey, String)>[
  (_SortKey.custom, '默认'),
  (_SortKey.pct, '涨跌幅'),
  (_SortKey.amount, '成交额'),
  (_SortKey.price, '价格'),
];

class WatchlistScreen extends StatefulWidget {
  final HomeController controller;

  /// 点某只股票 → 由根页负责切到详情页
  final ValueChanged<String> onSelect;

  const WatchlistScreen({
    super.key,
    required this.controller,
    required this.onSelect,
  });

  @override
  State<WatchlistScreen> createState() => _WatchlistScreenState();
}

class _WatchlistScreenState extends State<WatchlistScreen> {
  _SortKey _sortKey = _SortKey.custom;
  final _searchController = TextEditingController();

  /// symbol -> 最近 26 根收盘价。只读本地已缓存日线，不为画线发网络请求。
  final Map<String, List<double>> _closes = {};

  HomeController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    _searchController.text = controller.query;
    _loadCloses();
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
      _loadCloses();
    }
  }

  Future<void> _loadCloses() async {
    for (final item in controller.watchlist) {
      if (_closes.containsKey(item.symbol)) continue;
      final bars = await controller.repository.store.getDailyBars(item.symbol);
      if (!mounted) return;
      final values = [
        for (final bar in bars)
          if (bar.close != null) bar.close!,
      ];
      _closes[item.symbol] =
          values.length > 26 ? values.sublist(values.length - 26) : values;
    }
    if (mounted) setState(() {});
  }

  void _openSummary(String symbol) {
    controller.selectSymbol(symbol);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SummarySheet(controller: controller),
    );
  }

  Future<void> _confirmFullRefresh() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.panel,
        title: const Text(
          '强制全量刷新？',
          style: TextStyle(fontSize: FontSize.cardTitle, color: AppColors.text),
        ),
        content: const Text(
          '将重新拉取全市场股票清单与每只 90 天日线，覆盖本地数据。\n'
          '耗时数分钟且流量较大，期间八档局扫描不可用。',
          style: TextStyle(fontSize: FontSize.body, color: AppColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认刷新',
                style: TextStyle(color: AppColors.warn)),
          ),
        ],
      ),
    );
    if (ok == true) await controller.forceFullRefresh();
  }

  @override
  Widget build(BuildContext context) {
    final rows = [...controller.watchlist];
    double sortValue(String symbol, _SortKey key) {
      final quote =
          controller.quotes.where((item) => item.symbol == symbol).firstOrNull;
      switch (key) {
        case _SortKey.pct:
          return quote?.pctChg ?? double.negativeInfinity;
        case _SortKey.amount:
          return quote?.amount ?? double.negativeInfinity;
        case _SortKey.price:
          return quote?.price ?? double.negativeInfinity;
        case _SortKey.custom:
          return 0;
      }
    }

    if (_sortKey != _SortKey.custom) {
      rows.sort((a, b) =>
          sortValue(b.symbol, _sortKey).compareTo(sortValue(a.symbol, _sortKey)));
    }

    var up = 0;
    var down = 0;
    for (final item in rows) {
      final pct = controller.quotes
          .where((quote) => quote.symbol == item.symbol)
          .firstOrNull
          ?.pctChg;
      if (pct == null) continue;
      pct >= 0 ? up++ : down++;
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: hudBackgroundGradient),
        child: SafeArea(
          bottom: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _head(up, down, rows.length),
              SyncStatusStrip(controller: controller),
              _search(),
              if (controller.searchResults.isNotEmpty) _searchResults(),
              _sortChips(),
              Expanded(child: _list(rows)),
              _maintenance(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _head(int up, int down, int total) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const Text(
            '自选资产',
            style: TextStyle(
              fontSize: FontSize.screenTitle,
              fontWeight: FontWeight.w700,
              color: AppColors.text,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'A SHARE · $total',
              overflow: TextOverflow.clip,
              softWrap: false,
              style: mono(
                size: FontSize.capsLabel,
                color: AppColors.accent,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const Spacer(),
          Text('涨 $up',
              style: mono(size: FontSize.tableNumber, color: AppColors.rise)),
          Text(' · ',
              style: mono(size: FontSize.tableNumber, color: AppColors.textDim)),
          Text('跌 $down',
              style: mono(size: FontSize.tableNumber, color: AppColors.fall)),
          const SizedBox(width: 6),
          _refreshButton(),
        ],
      ),
    );
  }

  /// 手动刷新：重拉自选行情/板块，数据落后时再踢一次每日增量
  Widget _refreshButton() {
    final busy = controller.manualRefreshing;
    return GestureDetector(
      onTap: busy ? null : controller.refreshNow,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 30,
        height: 26,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.hudPanel,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: AppColors.hudBorder),
        ),
        child: busy
            ? const SizedBox(
                width: 13,
                height: 13,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: AppColors.accent),
              )
            : const Icon(Icons.refresh, size: 16, color: AppColors.accent),
      ),
    );
  }

  Widget _search() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
      child: HudPanel(
        radius: 10,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
        child: Row(
          children: [
            const Icon(Icons.search, size: 17, color: AppColors.textFaint),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: controller.search,
                style: const TextStyle(
                  fontSize: FontSize.secondaryNumber,
                  color: AppColors.text,
                ),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '代码 / 名称 / 拼音首字母',
                  hintStyle: TextStyle(
                    fontSize: FontSize.body,
                    color: AppColors.textFaint,
                  ),
                ),
              ),
            ),
            Text(
              'SEARCH',
              style: mono(
                size: FontSize.capsLabel,
                color: AppColors.accent,
                letterSpacing: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchResults() {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      decoration: BoxDecoration(
        color: AppColors.hudPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.hudBorder),
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final item in controller.searchResults)
            ListTile(
              dense: true,
              title: Text(
                item.display,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: FontSize.secondaryNumber,
                  color: AppColors.text,
                ),
              ),
              trailing:
                  const Icon(Icons.add, size: 18, color: AppColors.accent),
              onTap: () {
                controller.addSymbol(item.symbol);
                _searchController.clear();
              },
            ),
        ],
      ),
    );
  }

  Widget _sortChips() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Row(
        children: [
          for (final (key, label) in _sortLabels) ...[
            HudChip(
              label: label,
              active: _sortKey == key,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              onTap: () => setState(() => _sortKey = key),
            ),
            const SizedBox(width: 7),
          ],
        ],
      ),
    );
  }

  Widget _list(List<WatchlistItem> rows) {
    if (rows.isEmpty) {
      return const Center(
        child: Text(
          '还没有自选，搜索代码/名称添加',
          style: TextStyle(
            fontSize: FontSize.secondaryNumber,
            color: AppColors.textFaint,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, bottomNavSafePadding),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = rows[index];
        final quote =
            controller.quotes.where((q) => q.symbol == item.symbol).firstOrNull;
        return WatchlistRow(
          item: item,
          quote: quote,
          closes: _closes[item.symbol] ?? const [],
          // 热点 tag 只读批量取好的内存映射，渲染时不发请求
          sectors: controller.watchlistSectors[item.symbol],
          selected: controller.selected == item.symbol,
          onTap: () => widget.onSelect(item.symbol),
          onSummary: () => _openSummary(item.symbol),
          onRemove: () => controller.removeSymbol(item.symbol),
        );
      },
    );
  }

  /// 数据维护区：补齐数据 + 强制全量刷新（任务 E 的统一入口）
  Widget _maintenance() {
    final busy = controller.syncBusy;
    final repairCount = controller.pendingRepairCount;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.repairNote.isNotEmpty) ...[
            Text(
              controller.repairNote,
              overflow: TextOverflow.ellipsis,
              style: mono(size: FontSize.legend, color: AppColors.accent),
            ),
            const SizedBox(height: 6),
          ],
          Row(
            children: [
              Expanded(
                child: _MaintenanceButton(
                  icon: Icons.healing,
                  label: repairCount > 0 ? '补齐数据 $repairCount 只' : '补齐数据',
                  onTap: busy ? null : controller.repairData,
                  tone: repairCount > 0 ? AppColors.warn : AppColors.textMuted,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _MaintenanceButton(
                  icon: Icons.refresh,
                  label: '强制全量刷新',
                  onTap: busy ? null : _confirmFullRefresh,
                  tone: AppColors.textMuted,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 自选列表的一行：名称/代码/现价/涨跌幅 + 热点 tag + 资产信息按钮 + 左滑删除
class WatchlistRow extends StatelessWidget {
  final WatchlistItem item;
  final Quote? quote;
  final List<double> closes;
  final StockSectors? sectors;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onSummary;
  final VoidCallback onRemove;

  const WatchlistRow({
    super.key,
    required this.item,
    required this.quote,
    required this.closes,
    required this.sectors,
    required this.selected,
    required this.onTap,
    required this.onSummary,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final pct = quote?.pctChg;
    final tone = pct == null
        ? AppColors.textMuted
        : pct >= 0
            ? AppColors.rise
            : AppColors.fall;
    final hotName = (sectors?.hotConcepts.isNotEmpty ?? false)
        ? sectors!.hotConcepts.first
        : null;

    return Dismissible(
      key: ValueKey(item.symbol),
      direction: DismissDirection.endToStart,
      background: Container(
        decoration: BoxDecoration(
          color: AppColors.rise.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, size: 20, color: AppColors.rise),
      ),
      onDismissed: (_) => onRemove(),
      child: HudPanel(
        radius: 12,
        tint: pct == null ? null : tone,
        active: selected,
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
        onTap: onTap,
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // symbols 表（全市场同步）还没到位时退到行情里的名称，
                      // 两个都空才显示代码
                      Flexible(
                        child: Text(
                          quoteName(
                            item.symbol,
                            item.name.isNotEmpty ? item.name : quote?.name,
                          ),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: FontSize.cardTitle,
                            fontWeight: FontWeight.w600,
                            color: AppColors.text,
                          ),
                        ),
                      ),
                      if (hotName != null) ...[
                        const SizedBox(width: 6),
                        HotTag(name: hotName),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${item.symbol} · ${formatNumber(quote?.amount)}',
                    overflow: TextOverflow.ellipsis,
                    style: mono(size: FontSize.legend, color: AppColors.textDim),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Sparkline(
              values: closes,
              color: tone,
              fallbackPct: pct,
              size: const Size(44, 22),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatFullPrice(quote?.price),
                  style: mono(
                    size: FontSize.cardTitle,
                    color: tone,
                    weight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  formatPercent(pct),
                  style: mono(size: FontSize.secondaryNumber, color: tone),
                ),
              ],
            ),
            SizedBox(
              width: 34,
              height: 34,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 18,
                tooltip: '资产信息',
                onPressed: onSummary,
                icon: const Icon(Icons.insights_outlined,
                    color: AppColors.accent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 今日热点概念 tag（自选行上那枚）
class HotTag extends StatelessWidget {
  final String name;

  const HotTag({super.key, required this.name});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(3),
        color: AppColors.warn.withValues(alpha: 0.16),
        border: Border.all(color: AppColors.warn.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.local_fire_department, size: 10,
              color: AppColors.warn),
          const SizedBox(width: 2),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 66),
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: mono(size: FontSize.badge, color: AppColors.warn),
            ),
          ),
        ],
      ),
    );
  }
}

/// 数据流水线状态条：阶段文案 + 进度条 + 失败重试（任务 E 的可见提示）
class SyncStatusStrip extends StatelessWidget {
  final HomeController controller;

  const SyncStatusStrip({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final stage = controller.syncStage;
    final failed = stage == SyncStage.failed;
    final busy = controller.syncBusy;
    final color = failed
        ? AppColors.warn
        : stage == SyncStage.ready
            ? AppColors.textDim
            : AppColors.textMuted;
    final ratio = switch (stage) {
      SyncStage.initializing || SyncStage.fullRefreshing =>
        controller.syncProgress?.ratio,
      SyncStage.repairing => controller.repairTotal > 0
          ? controller.repairDone / controller.repairTotal
          : null,
      _ => null,
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (busy)
                SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                      strokeWidth: 1.5, color: color),
                )
              else
                Icon(failed ? Icons.warning_amber : Icons.sync,
                    size: 12, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      controller.syncText,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: mono(size: FontSize.legend, color: color),
                    ),
                    // 数据新鲜度：已更新到最新交易日的 / 还没更新的
                    if (controller.totalSymbolCount > 0)
                      Text(
                        '已最新 ${controller.freshCount} 只 · 待更新 ${controller.staleCount} 只',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: mono(
                          size: FontSize.legend,
                          color: controller.staleCount > 0
                              ? AppColors.warn
                              : AppColors.textFaint,
                        ),
                      ),
                  ],
                ),
              ),
              if (failed) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: controller.retrySync,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                          color: AppColors.warn.withValues(alpha: 0.6)),
                    ),
                    child: Text('重试',
                        style: mono(
                            size: FontSize.legend, color: AppColors.warn)),
                  ),
                ),
              ],
            ],
          ),
          if (busy && ratio != null) ...[
            const SizedBox(height: 5),
            HudSegmentBar(ratio: ratio),
          ],
        ],
      ),
    );
  }
}

class _MaintenanceButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color tone;

  const _MaintenanceButton({
    required this.icon,
    required this.label,
    required this.onTap,
    required this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final color = enabled ? tone : AppColors.textDim;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 34,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.hudBorder),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: TextStyle(fontSize: FontSize.body, color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
