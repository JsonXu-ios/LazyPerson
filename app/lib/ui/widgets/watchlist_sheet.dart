/// 自选资产弹层：搜索添加、排序、列表选中/删除。
/// 对齐 frontend/src/components/WatchlistPanel.tsx。
library;

import 'package:flutter/material.dart';

import '../../state/home_controller.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';

enum _SortKey { custom, pct, amount, price }

class WatchlistSheet extends StatefulWidget {
  final HomeController controller;

  const WatchlistSheet({super.key, required this.controller});

  @override
  State<WatchlistSheet> createState() => _WatchlistSheetState();
}

class _WatchlistSheetState extends State<WatchlistSheet> {
  _SortKey _sortKey = _SortKey.custom;
  final _searchController = TextEditingController();

  HomeController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    _searchController.text = controller.query;
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

  @override
  Widget build(BuildContext context) {
    final rows = [...controller.panelWatchlist];
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

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: Text('自选资产 · ${controller.activeConfig.label}',
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              child: TextField(
                controller: _searchController,
                onChanged: controller.search,
                style: const TextStyle(fontSize: 13, color: AppColors.text),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '代码 / 名称 / 拼音首字母',
                  hintStyle: const TextStyle(
                      fontSize: 12, color: AppColors.textFaint),
                  prefixIcon: const Icon(Icons.search,
                      size: 16, color: AppColors.textFaint),
                  filled: true,
                  fillColor: AppColors.background,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide:
                        const BorderSide(color: AppColors.panelBorder),
                  ),
                ),
              ),
            ),
            if (controller.searchResults.isNotEmpty)
              Container(
                constraints: const BoxConstraints(maxHeight: 180),
                margin: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  color: AppColors.background,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.panelBorder),
                ),
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final item in controller.searchResults)
                      ListTile(
                        dense: true,
                        title: Text(item.display,
                            style: const TextStyle(
                                fontSize: 12, color: AppColors.text)),
                        trailing: const Icon(Icons.add,
                            size: 16, color: AppColors.accent),
                        onTap: () {
                          controller.addSymbol(item.symbol);
                          _searchController.clear();
                          Navigator.of(context).pop();
                        },
                      ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 14, 2),
              child: Row(
                children: [
                  for (final (key, label) in const [
                    (_SortKey.custom, '默认'),
                    (_SortKey.pct, '涨跌幅'),
                    (_SortKey.amount, '成交额'),
                    (_SortKey.price, '价格'),
                  ]) ...[
                    GestureDetector(
                      onTap: () => setState(() => _sortKey = key),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: _sortKey == key
                              ? AppColors.axisBorder
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(label,
                            style: TextStyle(
                                fontSize: 11,
                                color: _sortKey == key
                                    ? AppColors.text
                                    : AppColors.textFaint)),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: rows.length,
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
                      color: AppColors.rise.withValues(alpha: 0.25),
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 20),
                      child: const Icon(Icons.delete,
                          size: 18, color: AppColors.rise),
                    ),
                    onDismissed: (_) => controller.removeSymbol(item.symbol),
                    child: ListTile(
                      dense: true,
                      selected: controller.selected == item.symbol,
                      selectedTileColor:
                          AppColors.accent.withValues(alpha: 0.08),
                      title: Text(quoteName(item.symbol, item.name),
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.text)),
                      subtitle: Text(item.symbol,
                          style: const TextStyle(
                              fontSize: 10, color: AppColors.textFaint)),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(formatFullPrice(quote?.price),
                              style: TextStyle(fontSize: 13, color: tone)),
                          Text(formatPercent(pct),
                              style: TextStyle(fontSize: 10, color: tone)),
                        ],
                      ),
                      onTap: () {
                        controller.selectSymbol(item.symbol);
                        Navigator.of(context).pop();
                      },
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
