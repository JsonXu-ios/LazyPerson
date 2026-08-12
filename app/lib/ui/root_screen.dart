/// 根页：标准底部导航（左=自选资产、中=八档局（突出）、右=热点板块）。
/// 默认落在自选资产页；点某只股票才推入个股详情页（K线+指标+资产信息）。
/// 三个 tab 用 IndexedStack 保持各自状态；未访问过的 tab 延迟到首次点击才
/// 构建，避免热点板块一开机就去拉榜单。
library;

import 'package:flutter/material.dart';

import '../data/popularity_service.dart';
import '../state/band_scan_controller.dart';
import '../state/home_controller.dart';
import '../state/sector_controller.dart';
import '../theme/app_theme.dart';
import 'band_scan_screen.dart';
import 'sector_screen.dart';
import 'breakout_screen.dart';
import 'popular_screen.dart';
import 'stock_detail_screen.dart';
import 'watchlist_screen.dart';

/// tab 下标：自选资产 | 破势 | 八档局(凸起) | 热点板块 | 人气股
const watchlistTab = 0;
const breakoutTab = 1;
const bandScanTab = 2;
const sectorTab = 3;
const popularTab = 4;
const tabCount = 5;

class RootScreen extends StatefulWidget {
  final HomeController controller;

  const RootScreen({super.key, required this.controller});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  int _index = watchlistTab;

  /// 已经访问过的 tab（未访问的先占位，别在开机时触发它们的 initState 取数）
  final Set<int> _visited = {watchlistTab};

  BandScanController? _bandScan;
  SectorController? _sectors;
  PopularityService? _popularity;

  HomeController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(_onChanged);
    controller.bootstrap();
  }

  @override
  void dispose() {
    controller.removeListener(_onChanged);
    _bandScan?.dispose();
    _sectors?.dispose();
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  void _select(int index) {
    if (index == _index) return;
    setState(() {
      _index = index;
      _visited.add(index);
    });
  }

  /// 任一 tab 里点某只股票 → 选中并推入详情页
  void _openDetail(String symbol) {
    controller.selectSymbol(symbol);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StockDetailScreen(controller: controller),
      ),
    );
  }

  Widget _page(int index) {
    if (!_visited.contains(index)) return const SizedBox.shrink();
    switch (index) {
      case bandScanTab:
        final band = _bandScan ??= BandScanController(controller.repository);
        return BandScanScreen(controller: band, onSelect: _openDetail);
      case breakoutTab:
        final band = _bandScan ??= BandScanController(controller.repository);
        return BreakoutScreen(
          controller: band,
          sectors: controller.repository.sectors,
          onSelect: _openDetail,
        );
      case popularTab:
        final service = _popularity ??= PopularityService(
          store: controller.repository.store,
          sectors: controller.repository.sectors,
          tencent: controller.repository.tencent,
        );
        return PopularScreen(service: service, onSelect: _openDetail);
      case sectorTab:
        final sectors =
            _sectors ??= SectorController(controller.repository.sectors);
        return SectorScreen(controller: sectors, onSelect: _openDetail);
      default:
        return WatchlistScreen(controller: controller, onSelect: _openDetail);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      extendBody: true,  // 让凸起的圆钮压在内容之上
      body: IndexedStack(
        index: _index,
        children: [for (var i = 0; i < tabCount; i++) _page(i)],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: BandScanFab(
        active: _index == bandScanTab,
        onTap: () => _select(bandScanTab),
      ),
      bottomNavigationBar: HudBottomNav(index: _index, onSelect: _select),
    );
  }
}

/// HUD 风格底部导航：带圆形缺口的 BottomAppBar，八档局是嵌在缺口里的凸起圆钮
/// （半圆露在导航栏上方），左右各一格普通 tab。
class HudBottomNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;

  const HudBottomNav({super.key, required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return BottomAppBar(
      color: AppColors.panel.withValues(alpha: 0.98),
      elevation: 0,
      // 缺口比圆钮直径大 8dp，圆钮四周留一圈均匀的呼吸位
      shape: const CircularNotchedRectangle(),
      notchMargin: 8,
      padding: EdgeInsets.zero,
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.hudBorder)),
        ),
        child: Row(
          children: [
            Expanded(
              child: _NavTab(
                icon: Icons.dashboard_customize_outlined,
                activeIcon: Icons.dashboard_customize,
                label: '自选资产',
                active: index == watchlistTab,
                onTap: () => onSelect(watchlistTab),
              ),
            ),
            Expanded(
              child: _NavTab(
                icon: Icons.trending_up_outlined,
                activeIcon: Icons.trending_up,
                label: '破势',
                active: index == breakoutTab,
                onTap: () => onSelect(breakoutTab),
              ),
            ),
            // 缺口宽度：圆钮直径 + 两侧 notchMargin（中间留给八档局凸起钮）
            const SizedBox(width: 80),
            Expanded(
              child: _NavTab(
                icon: Icons.local_fire_department_outlined,
                activeIcon: Icons.local_fire_department,
                label: '热点板块',
                active: index == sectorTab,
                onTap: () => onSelect(sectorTab),
              ),
            ),
            Expanded(
              child: _NavTab(
                icon: Icons.people_alt_outlined,
                activeIcon: Icons.people_alt,
                label: '人气股',
                active: index == popularTab,
                onTap: () => onSelect(popularTab),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 左右两格的普通 tab（图标 + 文字，选中变 accent）
class _NavTab extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _NavTab({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = active ? AppColors.accent : AppColors.textFaint;
    return InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(active ? activeIcon : icon, size: 21, color: color),
          const SizedBox(height: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: FontSize.legend,
              color: color,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// 八档局：嵌在导航缺口里的凸起圆钮，半圆露在导航栏上方
class BandScanFab extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;

  const BandScanFab({super.key, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: 64,
      child: FloatingActionButton(
        onPressed: onTap,
        elevation: 0,
        highlightElevation: 0,
        backgroundColor: active
            ? AppColors.accent
            : AppColors.panel,
        shape: CircleBorder(
          side: BorderSide(
            color: AppColors.accent.withValues(alpha: active ? 1 : 0.6),
            width: 2,
          ),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.radar,
              size: 22,
              color: active ? const Color(0xFF050914) : AppColors.accent,
            ),
            const SizedBox(height: 1),
            Text(
              '八档局',
              style: TextStyle(
                fontSize: 9,
                height: 1.1,
                fontWeight: FontWeight.w700,
                color: active ? const Color(0xFF050914) : AppColors.accent,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

