/// 个股行业与概念标签（资产信息浮层里的一行）。
/// 对齐 frontend/src/components/StockSummary.tsx 的 IndustryLine：
/// 行业一个主标签 + 最多 5 个概念标签，命中今日热点的概念用 warn 色标出。
library;

import 'package:flutter/material.dart';

import '../../data/sector_service.dart';
import '../../data/symbol_utils.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';

/// 概念标签最多展示几个（对齐 IndustryLine 的 concepts.slice(0, 5)）
const sectorTagMaxConcepts = 5;

class SectorTags extends StatefulWidget {
  final SectorService sectors;
  final String symbol;

  const SectorTags({super.key, required this.sectors, required this.symbol});

  @override
  State<SectorTags> createState() => _SectorTagsState();
}

class _SectorTagsState extends State<SectorTags> {
  StockSectors? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SectorTags oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.symbol != widget.symbol) _load();
  }

  /// 取不到就整行不渲染（对齐网页版：没有数据不占位）
  Future<void> _load() async {
    final symbol = widget.symbol;
    if (!isAShareSymbol(symbol)) {
      if (mounted) setState(() => _data = null);
      return;
    }
    setState(() => _data = null);
    try {
      final data = await widget.sectors.sectorsOf(symbol);
      if (!mounted || symbol != widget.symbol) return;
      setState(() => _data = data);
    } catch (_) {
      if (!mounted || symbol != widget.symbol) return;
      setState(() => _data = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null || data.isEmpty) return const SizedBox.shrink();
    final concepts = data.concepts.length > sectorTagMaxConcepts
        ? data.concepts.sublist(0, sectorTagMaxConcepts)
        : data.concepts;
    final hot = data.hotConcepts.toSet();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          if (data.industry.isNotEmpty)
            _Tag(label: data.industry, primary: true),
          for (final name in concepts) _Tag(label: name, hot: hot.contains(name)),
        ],
      ),
    );
  }
}

/// 行业主标签用 accent 描边，热点概念用 warn，其余概念用弱描边
class _Tag extends StatelessWidget {
  final String label;
  final bool primary;
  final bool hot;

  const _Tag({required this.label, this.primary = false, this.hot = false});

  @override
  Widget build(BuildContext context) {
    final color = primary
        ? AppColors.accent
        : hot
            ? AppColors.warn
            : AppColors.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        color: color.withValues(alpha: primary || hot ? 0.14 : 0.0),
        border: Border.all(
          color: color.withValues(alpha: primary || hot ? 0.65 : 0.35),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hot) ...[
            const Icon(Icons.local_fire_department,
                size: 11, color: AppColors.warn),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: FontSize.legend,
              color: color,
              fontWeight: primary || hot ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
