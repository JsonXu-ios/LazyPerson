/// 人气股：东方财富人气榜 TOP100，带排名变化、行情与所属行业/概念。
library;

import 'package:flutter/material.dart';

import '../data/popularity_service.dart';
import '../theme/app_theme.dart';

class PopularScreen extends StatefulWidget {
  final PopularityService service;
  final ValueChanged<String> onSelect;

  const PopularScreen({
    super.key,
    required this.service,
    required this.onSelect,
  });

  @override
  State<PopularScreen> createState() => _PopularScreenState();
}

class _PopularScreenState extends State<PopularScreen> {
  List<PopularStock> _rows = [];
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await widget.service.topStocks(refresh: refresh);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (exc) {
      if (!mounted) return;
      setState(() {
        _error = '$exc';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: hudBackgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Text(
                    _error!,
                    style: mono(size: FontSize.legend, color: AppColors.warn),
                  ),
                ),
              Expanded(
                child: _rows.isEmpty
                    ? Center(
                        child: Text(
                          _loading ? '加载中…' : '暂无数据',
                          style: const TextStyle(
                            fontSize: FontSize.secondaryNumber,
                            color: AppColors.textFaint,
                          ),
                        ),
                      )
                    : RefreshIndicator(
                        color: AppColors.accent,
                        backgroundColor: AppColors.hudPanel,
                        onRefresh: () => _load(refresh: true),
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 90),
                          itemCount: _rows.length,
                          itemBuilder: (context, index) => _PopularRow(
                            row: _rows[index],
                            onTap: () => widget.onSelect(_rows[index].symbol),
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

  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '人气股 · TOP100',
                  style: TextStyle(
                    fontSize: FontSize.screenTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '东方财富人气榜 · 下拉刷新',
                  style: mono(size: FontSize.legend, color: AppColors.textDim),
                ),
              ],
            ),
          ),
          if (_loading)
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
}

class _PopularRow extends StatelessWidget {
  final PopularStock row;
  final VoidCallback onTap;

  const _PopularRow({required this.row, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final up = (row.pctChg ?? 0) >= 0;
    final change = row.rankChange ?? 0;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.hudPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.hudBorder),
        ),
        child: Row(
          children: [
            // 排名 + 升降
            SizedBox(
              width: 40,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${row.rank}',
                    style: mono(
                      size: FontSize.cardTitle,
                      color: row.rank <= 10 ? AppColors.accent : AppColors.text,
                      weight: FontWeight.w700,
                    ),
                  ),
                  if (change != 0)
                    Text(
                      '${change > 0 ? '↑' : '↓'}${change.abs().toInt()}',
                      style: mono(
                        size: FontSize.legend,
                        color: change > 0 ? AppColors.rise : AppColors.fall,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 名称 + 板块
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          row.name.isEmpty ? row.symbol : row.name,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: FontSize.secondaryNumber,
                            fontWeight: FontWeight.w600,
                            color: AppColors.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        row.symbol,
                        style: mono(
                            size: FontSize.legend, color: AppColors.textFaint),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    [
                      if (row.industry.isNotEmpty) row.industry,
                      ...row.concepts.take(2),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style:
                        mono(size: FontSize.legend, color: AppColors.textDim),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 现价 + 涨跌
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  row.price?.toStringAsFixed(2) ?? '-',
                  style: mono(
                      size: FontSize.secondaryNumber, color: AppColors.text),
                ),
                const SizedBox(height: 3),
                Text(
                  row.pctChg == null
                      ? '-'
                      : '${up ? '+' : ''}${row.pctChg!.toStringAsFixed(2)}%',
                  style: mono(
                    size: FontSize.secondaryNumber,
                    color: up ? AppColors.rise : AppColors.fall,
                    weight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
