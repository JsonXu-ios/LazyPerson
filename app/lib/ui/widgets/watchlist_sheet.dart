/// 自选资产浮层（HUD 方案 1d，稿 11）：搜索添加、排序、走势线、左滑删除。
/// 对齐 frontend/src/components/WatchlistPanel.tsx。
library;

import 'package:flutter/material.dart';

import '../../state/home_controller.dart';
import '../../theme/app_theme.dart';
import '../../theme/hud.dart';
import '../../utils/format.dart';
import 'hud_sheet.dart';
import 'sparkline.dart';

enum _SortKey { custom, pct, amount, price }

const _sortLabels = <(_SortKey, String)>[
  (_SortKey.custom, '默认'),
  (_SortKey.pct, '涨跌幅'),
  (_SortKey.amount, '成交额'),
  (_SortKey.price, '价格'),
];

class WatchlistSheet extends StatefulWidget {
  final HomeController controller;

  const WatchlistSheet({super.key, required this.controller});

  @override
  State<WatchlistSheet> createState() => _WatchlistSheetState();
}

class _WatchlistSheetState extends State<WatchlistSheet> {
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
    if (mounted) setState(() {});
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
      rows.sort((a, b) => sortValue(b.symbol, _sortKey)
          .compareTo(sortValue(a.symbol, _sortKey)));
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

    return HudSheet(
      heightFactor: 0.81,
      child: Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _head(up, down, rows.length),
            _search(),
            if (controller.searchResults.isNotEmpty) _searchResults(),
            _sortChips(),
            Expanded(child: _list(rows)),
            _hint(),
          ],
        ),
      ),
    );
  }

  Widget _head(int up, int down, int total) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          const Text('自选资产',
              style: TextStyle(
                  fontSize: FontSize.screenTitle,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text)),
          const SizedBox(width: 8),
          Text('A SHARE · $total',
              style: mono(
                  size: FontSize.capsLabel,
                  color: AppColors.accent,
                  letterSpacing: 1.2)),
          const Spacer(),
          Text('涨 $up',
              style: mono(size: FontSize.tableNumber, color: AppColors.rise)),
          Text(' · ',
              style: mono(size: FontSize.tableNumber, color: AppColors.textDim)),
          Text('跌 $down',
              style: mono(size: FontSize.tableNumber, color: AppColors.fall)),
        ],
      ),
    );
  }

  Widget _search() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
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
                    fontSize: FontSize.secondaryNumber, color: AppColors.text),
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  hintText: '代码 / 名称 / 拼音首字母',
                  hintStyle: TextStyle(
                      fontSize: FontSize.body, color: AppColors.textFaint),
                ),
              ),
            ),
            Text('SEARCH',
                style: mono(
                    size: FontSize.capsLabel,
                    color: AppColors.accent,
                    letterSpacing: 1.6)),
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
              title: Text(item.display,
                  style: const TextStyle(
                      fontSize: FontSize.secondaryNumber,
                      color: AppColors.text)),
              trailing:
                  const Icon(Icons.add, size: 18, color: AppColors.accent),
              onTap: () {
                controller.addSymbol(item.symbol);
                _searchController.clear();
                Navigator.of(context).pop();
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
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              onTap: () => setState(() => _sortKey = key),
            ),
            const SizedBox(width: 7),
          ],
        ],
      ),
    );
  }

  Widget _list(List<dynamic> rows) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: rows.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = rows[index];
        final quote = controller.quotes
            .where((q) => q.symbol == item.symbol)
            .firstOrNull;
        final pct = quote?.pctChg;
        final tone = pct == null
            ? AppColors.textMuted
            : pct >= 0
                ? AppColors.rise
                : AppColors.fall;
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
          onDismissed: (_) => controller.removeSymbol(item.symbol),
          child: HudPanel(
            radius: 12,
            tint: pct == null ? null : tone,
            active: controller.selected == item.symbol,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            onTap: () {
              controller.selectSymbol(item.symbol);
              Navigator.of(context).pop();
            },
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(quoteName(item.symbol, item.name),
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: FontSize.cardTitle,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text)),
                      const SizedBox(height: 3),
                      Text(
                        '${item.symbol} · ${formatNumber(quote?.amount)}',
                        style: mono(
                            size: FontSize.legend, color: AppColors.textDim),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Sparkline(
                  values: _closes[item.symbol] ?? const [],
                  color: tone,
                  fallbackPct: pct,
                ),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(formatFullPrice(quote?.price),
                        style: mono(
                            size: FontSize.cardTitle,
                            color: tone,
                            weight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(formatPercent(pct),
                        style:
                            mono(size: FontSize.secondaryNumber, color: tone)),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _hint() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Row(
        children: [
          Container(width: 16, height: 1, color: AppColors.accent),
          const SizedBox(width: 8),
          Text('SWIPE LEFT TO REMOVE · TAP TO CHART',
              style: mono(
                  size: FontSize.capsLabel,
                  color: AppColors.textDim,
                  letterSpacing: 1.2)),
        ],
      ),
    );
  }
}
