/// 热点板块页状态：行业/概念两个榜单（涨幅降序 Top N）+ 展开的板块成分股。
/// 对齐 frontend/src/components/HotSectorPanel.tsx。
library;

import 'package:flutter/foundation.dart';

import '../data/sector_service.dart';
import '../models/models.dart';

/// 榜单展示条数（对齐 HotSectorPanel 的 limit=20）
const sectorTopLimit = 20;

/// 展开时拉多少成分股（对齐 HotSectorPanel 的 sectorConstituents(code, 40)）
const sectorConstituentLimit = 40;

class SectorController extends ChangeNotifier {
  final SectorService sectors;

  SectorController(this.sectors);

  HotSectors data = const HotSectors();
  bool loading = false;
  String error = '';

  /// 当前 tab：industry | concept
  String kind = sectorKindConcept;

  /// 展开的板块（null = 都收起）
  SectorBoard? openBoard;
  List<SectorConstituent> constituents = const [];
  bool constituentsLoading = false;

  bool _disposed = false;
  int _consRunId = 0;

  List<SectorBoard> get boards =>
      kind == sectorKindIndustry ? data.industries : data.concepts;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _consRunId += 1;
    super.dispose();
  }

  void setKind(String value) {
    if (value == kind) return;
    kind = value;
    // 换榜时收起展开项：两个榜的板块不是一回事
    openBoard = null;
    constituents = const [];
    _notify();
  }

  Future<void> load({bool refresh = false}) async {
    if (loading) return;
    loading = true;
    error = '';
    _notify();
    try {
      data = await sectors.hotBoards(limit: sectorTopLimit, refresh: refresh);
      if (data.isEmpty) error = '板块数据暂不可用';
    } catch (exc) {
      error = '$exc';
    } finally {
      loading = false;
      _notify();
    }
  }

  /// 点同一个板块 = 收起；点别的 = 换成它并拉成分股
  Future<void> toggleBoard(SectorBoard board) async {
    if (openBoard?.code == board.code) {
      openBoard = null;
      constituents = const [];
      _notify();
      return;
    }
    final runId = ++_consRunId;
    openBoard = board;
    constituents = const [];
    constituentsLoading = true;
    _notify();
    try {
      final rows = await sectors.constituents(board.code,
          limit: sectorConstituentLimit);
      if (runId != _consRunId) return;
      constituents = rows;
    } catch (exc) {
      if (runId != _consRunId) return;
      constituents = const [];
      error = '$exc';
    } finally {
      if (runId == _consRunId) {
        constituentsLoading = false;
        _notify();
      }
    }
  }
}
