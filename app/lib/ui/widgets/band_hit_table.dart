/// 八档局命中表（HUD 版九列表格，横向可滚动）。
/// 与 band_radar.dart 搭配：雷达选档 → 本表列出该档命中。
/// 与卡片版（HANDOFF 3.4）互斥，二选一或用 BandHitView 开关切换。
/// 新增文件：lib/ui/widgets/band_hit_table.dart
library;

import 'package:flutter/material.dart';

import '../../logic/band_scanner.dart' show BandHit;
import '../../theme/app_theme.dart';

/// 列宽合计 > 411，所以整表横向滚动；前两列（代码/名称）冻结在左侧。
const _frozenWidth = 128.0;
const _columns = <(String, double)>[
  ('最新价', 64),
  ('90日低点', 74),
  ('涨幅', 62),
  ('波段高', 62),
  ('低点日', 58),
  ('过线日', 58),
  ('超出', 60),
  ('形态', 72),
];

class BandHitTable extends StatefulWidget {
  final List<BandHit> hits;
  final ValueChanged<String> onSelect;
  final bool running;

  const BandHitTable({
    super.key,
    required this.hits,
    required this.onSelect,
    this.running = false,
  });

  @override
  State<BandHitTable> createState() => _BandHitTableState();
}

class _BandHitTableState extends State<BandHitTable> {
  /// 表头与表体共用一个横向控制器，保证滚动同步
  final _horizontal = ScrollController();

  @override
  void dispose() {
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.hits.isEmpty) {
      return Center(
        child: Text(
          widget.running ? '本档暂无命中（扫描中…）' : '本档无命中',
          style: const TextStyle(
              fontSize: FontSize.body, color: AppColors.textFaint),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        Expanded(
          child: ListView.separated(
            itemCount: widget.hits.length,
            separatorBuilder: (_, _) => Container(
              height: 1,
              color: AppColors.grid,
            ),
            itemBuilder: (context, index) => _row(widget.hits[index], index),
          ),
        ),
      ],
    );
  }

  Widget _header() {
    final style = mono(
      size: FontSize.legend,
      color: AppColors.textFaint,
      weight: FontWeight.w600,
      letterSpacing: 0.6,
    );
    return Container(
      decoration: BoxDecoration(
        color: AppColors.hudPanel,
        border: Border(
          top: BorderSide(color: AppColors.hudBorder),
          bottom: BorderSide(color: AppColors.hudBorder),
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          SizedBox(
            width: _frozenWidth,
            child: Padding(
              padding: const EdgeInsets.only(left: 14),
              child: Text('代码 / 名称', style: style),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              controller: _horizontal,
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              child: Row(
                children: [
                  for (final (label, width) in _columns)
                    SizedBox(
                      width: width,
                      child: Text(label, style: style, textAlign: TextAlign.right),
                    ),
                  const SizedBox(width: 14),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(BandHit hit, int index) {
    final cell = mono(size: FontSize.tableNumber, color: AppColors.text);
    final dim = mono(size: FontSize.tableNumber, color: AppColors.textFaint);
    return InkWell(
      onTap: () => widget.onSelect(hit.symbol),
      child: Container(
        color: hit.limitUp
            ? AppColors.rise.withValues(alpha: 0.06)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            SizedBox(
              width: _frozenWidth,
              child: Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (hit.limitUp)
                          Container(
                            width: 5,
                            height: 5,
                            margin: const EdgeInsets.only(right: 5),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: AppColors.rise,
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.rise.withValues(alpha: 0.7),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                        Flexible(
                          child: Text(
                            hit.name,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: FontSize.cardTitle,
                              fontWeight: FontWeight.w600,
                              color: AppColors.text,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(hit.symbol,
                        style: mono(
                            size: FontSize.legend, color: AppColors.textDim)),
                  ],
                ),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _c(0, Text(hit.price.toStringAsFixed(2),
                        textAlign: TextAlign.right,
                        style: mono(
                            size: FontSize.tableNumber,
                            color: AppColors.rise,
                            weight: FontWeight.w600))),
                    _c(1, Text(hit.low90.toStringAsFixed(2), textAlign: TextAlign.right, style: cell)),
                    _c(2, Text('${hit.pct.toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: mono(
                            size: FontSize.secondaryNumber,
                            color: AppColors.rise,
                            weight: FontWeight.w700))),
                    _c(3, Text('${hit.maxPct.toStringAsFixed(1)}%', textAlign: TextAlign.right, style: cell)),
                    _c(4, Text(_short(hit.lowDate), textAlign: TextAlign.right, style: dim)),
                    _c(5, Text(_short(hit.crossDate), textAlign: TextAlign.right, style: dim)),
                    _c(6, Text('+${hit.over.toStringAsFixed(1)}%',
                        textAlign: TextAlign.right,
                        style: mono(
                            size: FontSize.tableNumber,
                            color: AppColors.warn,
                            weight: FontWeight.w600))),
                    _c(7, Text(_shape(hit),
                        textAlign: TextAlign.right,
                        style: mono(
                            size: FontSize.badge, color: AppColors.textDim))),
                    const SizedBox(width: 14),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _c(int index, Widget child) =>
      SizedBox(width: _columns[index].$2, child: child);

  String _short(String date) => date.length >= 10 ? date.substring(5) : date;

  /// 「从高处来」标记，两条都命中时并排显示
  String _shape(BandHit hit) => [
        if (hit.fromTop) '顶部下来',
        if (hit.vShape) 'V型',
      ].join(' ');
}

/// 表格 / 卡片切换（放在雷达右上角，状态存在 BandScanScreen 的 State 即可，
/// 不要写进 controller —— 它是纯展示偏好）。
class BandViewToggle extends StatelessWidget {
  final bool table;
  final ValueChanged<bool> onChanged;

  const BandViewToggle({super.key, required this.table, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _btn(Icons.table_rows_outlined, table, () => onChanged(true)),
        const SizedBox(width: 4),
        _btn(Icons.view_agenda_outlined, !table, () => onChanged(false)),
      ],
    );
  }

  Widget _btn(IconData icon, bool active, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: active ? AppColors.hudFillActive : Colors.transparent,
            border: Border.all(
              color: active ? AppColors.hudBorderActive : AppColors.hudBorder,
            ),
          ),
          child: Icon(
            icon,
            size: 15,
            color: active ? AppColors.accent : AppColors.textFaint,
          ),
        ),
      );
}
