/// 热点板块页（HUD 风格）：行业/概念两个 tab，按涨幅降序 Top 20，
/// 点板块展开成分股，点成分股切主图并关页。
/// 对齐 frontend/src/components/HotSectorPanel.tsx。
library;

import 'package:flutter/material.dart';

import '../data/sector_service.dart';
import '../models/models.dart';
import '../state/sector_controller.dart';
import '../theme/app_theme.dart';
import '../theme/hud.dart';

class SectorScreen extends StatefulWidget {
  final SectorController controller;
  final ValueChanged<String> onSelect;

  const SectorScreen({
    super.key,
    required this.controller,
    required this.onSelect,
  });

  @override
  State<SectorScreen> createState() => _SectorScreenState();
}

class _SectorScreenState extends State<SectorScreen> {
  SectorController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.load();
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
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DecoratedBox(
        decoration: const BoxDecoration(gradient: hudBackgroundGradient),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _appBar(),
              _tabs(),
              if (controller.error.isNotEmpty) _failure(),
              Expanded(child: _list()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 0),
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
                  '今日热点板块',
                  style: TextStyle(
                    fontSize: FontSize.screenTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'EASTMONEY · TOP $sectorTopLimit BY CHG',
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
          IconButton(
            iconSize: 20,
            onPressed:
                controller.loading ? null : () => controller.load(refresh: true),
            icon: controller.loading
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.accent,
                    ),
                  )
                : const Icon(Icons.refresh, color: AppColors.accent),
          ),
        ],
      ),
    );
  }

  Widget _tabs() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Row(
        children: [
          Expanded(
            child: _TabCell(
              label: '概念板块',
              active: controller.kind == sectorKindConcept,
              onTap: () => controller.setKind(sectorKindConcept),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _TabCell(
              label: '行业板块',
              active: controller.kind == sectorKindIndustry,
              onTap: () => controller.setKind(sectorKindIndustry),
            ),
          ),
        ],
      ),
    );
  }

  Widget _failure() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(
        controller.error,
        style: const TextStyle(
          fontSize: FontSize.body,
          color: AppColors.warn,
        ),
      ),
    );
  }

  Widget _list() {
    final boards = controller.boards;
    if (boards.isEmpty) {
      return Center(
        child: Text(
          controller.loading ? '加载中…' : '暂无板块数据',
          style: const TextStyle(
            fontSize: FontSize.secondaryNumber,
            color: AppColors.textFaint,
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
      itemCount: boards.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final board = boards[index];
        final open = controller.openBoard?.code == board.code;
        return _BoardCard(
          board: board,
          rank: index + 1,
          open: open,
          loading: open && controller.constituentsLoading,
          constituents: open ? controller.constituents : const [],
          onTap: () => controller.toggleBoard(board),
          onSelect: widget.onSelect,
        );
      },
    );
  }
}

/// 榜单 tab：选中态与八档局的筛选 chip 同一套视觉
class _TabCell extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _TabCell({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: active ? AppColors.hudFillActive : Colors.transparent,
          border: Border.all(
            color: active ? AppColors.hudBorderActive : AppColors.hudBorder,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: FontSize.secondaryNumber,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? AppColors.text : AppColors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// 板块卡：名次 + 名称 + 涨幅 + 领涨股，展开后接成分股列表
class _BoardCard extends StatelessWidget {
  final SectorBoard board;
  final int rank;
  final bool open;
  final bool loading;
  final List<SectorConstituent> constituents;
  final VoidCallback onTap;
  final ValueChanged<String> onSelect;

  const _BoardCard({
    required this.board,
    required this.rank,
    required this.open,
    required this.loading,
    required this.constituents,
    required this.onTap,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final pct = board.pctChg ?? 0;
    return HudPanel(
      radius: 12,
      active: open,
      // 前三名给发光，一眼看到今天最强的
      glow: rank <= 3,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 22,
                child: Text(
                  '$rank',
                  style: mono(
                    size: FontSize.tableNumber,
                    color: rank <= 3 ? AppColors.warn : AppColors.textDim,
                    weight: FontWeight.w700,
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  board.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: FontSize.cardTitle,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%',
                style: mono(
                  size: FontSize.secondaryNumber,
                  color: pct >= 0 ? AppColors.rise : AppColors.fall,
                  weight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                open ? Icons.expand_less : Icons.expand_more,
                size: 17,
                color: AppColors.textDim,
              ),
            ],
          ),
          if (board.leader.isNotEmpty) ...[
            const SizedBox(height: 5),
            Padding(
              padding: const EdgeInsets.only(left: 22),
              // 领涨股名可能很长：整组用 Expanded + ellipsis 堵住横向溢出，
              // 涨跌家数固定在右侧（整屏 widget 不进 layout_overflow_test，
              // 只能靠结构挡）
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            '领涨 ${board.leader}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: FontSize.legend,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                        if (board.leaderPct != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            '${board.leaderPct! >= 0 ? '+' : ''}${board.leaderPct!.toStringAsFixed(2)}%',
                            style: mono(
                              size: FontSize.legend,
                              color: board.leaderPct! >= 0
                                  ? AppColors.rise
                                  : AppColors.fall,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (board.upCount != null && board.downCount != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '涨${board.upCount} 跌${board.downCount}',
                      style: mono(
                        size: FontSize.legend,
                        color: AppColors.textFaint,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (open) ...[
            const SizedBox(height: 9),
            Container(height: 1, color: AppColors.hudBorder),
            const SizedBox(height: 8),
            if (loading)
              const Text(
                '成分股加载中…',
                style: TextStyle(
                  fontSize: FontSize.legend,
                  color: AppColors.textFaint,
                ),
              )
            else if (constituents.isEmpty)
              const Text(
                '暂无成分股数据',
                style: TextStyle(
                  fontSize: FontSize.legend,
                  color: AppColors.textFaint,
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final item in constituents)
                    _ConstituentCell(
                      item: item,
                      onTap: () => onSelect(item.symbol),
                    ),
                ],
              ),
          ],
        ],
      ),
    );
  }
}

/// 成分股小卡：名称 + 涨幅，点了切主图
class _ConstituentCell extends StatelessWidget {
  final SectorConstituent item;
  final VoidCallback onTap;

  const _ConstituentCell({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final pct = item.pctChg ?? 0;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 108,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.hudBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.name.isEmpty ? item.symbol : item.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: FontSize.body,
                color: AppColors.text,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(2)}%',
              style: mono(
                size: FontSize.legend,
                color: pct >= 0 ? AppColors.rise : AppColors.fall,
                weight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
