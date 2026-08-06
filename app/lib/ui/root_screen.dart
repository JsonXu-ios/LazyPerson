/// 根页：标准底部导航（左=自选资产、中=八档局（突出）、右=热点板块）。
/// 默认落在自选资产页；点某只股票才推入个股详情页（K线+指标+资产信息）。
/// 三个 tab 用 IndexedStack 保持各自状态；未访问过的 tab 延迟到首次点击才
/// 构建，避免热点板块一开机就去拉榜单。
library;

import 'package:flutter/material.dart';

import '../state/band_scan_controller.dart';
import '../state/home_controller.dart';
import '../state/sector_controller.dart';
import '../theme/app_theme.dart';
import 'band_scan_screen.dart';
import 'sector_screen.dart';
import 'stock_detail_screen.dart';
import 'watchlist_screen.dart';

/// tab 下标：与 [_navItems] 一一对应
const watchlistTab = 0;
const bandScanTab = 1;
const sectorTab = 2;

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
      body: IndexedStack(
        index: _index,
        children: [for (var i = 0; i < 3; i++) _page(i)],
      ),
      bottomNavigationBar: HudBottomNav(index: _index, onSelect: _select),
    );
  }
}

/// HUD 风格的标准底部导航：三格，中间的八档局用 accent 实心胶囊 + 发光突出。
class HudBottomNav extends StatelessWidget {
  final int index;
  final ValueChanged<int> onSelect;

  const HudBottomNav({super.key, required this.index, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.panel.withValues(alpha: 0.96),
        border: Border(top: BorderSide(color: AppColors.hudBorder)),
      ),
      child: SafeArea(
        top: false,
        child: BottomNavigationBar(
          currentIndex: index,
          onTap: onSelect,
          type: BottomNavigationBarType.fixed,
          backgroundColor: Colors.transparent,
          elevation: 0,
          selectedItemColor: AppColors.accent,
          unselectedItemColor: AppColors.textFaint,
          selectedFontSize: FontSize.legend,
          unselectedFontSize: FontSize.legend,
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.dashboard_customize_outlined),
              activeIcon: Icon(Icons.dashboard_customize),
              label: '自选资产',
            ),
            BottomNavigationBarItem(
              icon: _BandScanIcon(active: index == bandScanTab),
              label: '八档局',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.local_fire_department_outlined),
              activeIcon: Icon(Icons.local_fire_department),
              label: '热点板块',
            ),
          ],
        ),
      ),
    );
  }
}

/// 中间那格的突出图标：实心胶囊 + 外发光，选中时更亮
class _BandScanIcon extends StatelessWidget {
  final bool active;

  const _BandScanIcon({required this.active});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 26,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(13),
        color: AppColors.accent.withValues(alpha: active ? 0.95 : 0.20),
        border: Border.all(
          color: AppColors.accent.withValues(alpha: active ? 1 : 0.55),
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: active ? 0.45 : 0.18),
            blurRadius: active ? 18 : 10,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Icon(
        Icons.radar,
        size: 18,
        color: active ? const Color(0xFF050914) : AppColors.accent,
      ),
    );
  }
}
