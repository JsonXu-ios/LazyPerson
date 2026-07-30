/// 资产信息里的财务区：估值 + 最近几期业绩 + 分红方案。
/// 数据来自东财 datacenter（MarketRepository.fundamentals），仅 A 股有。
/// 对齐 frontend/src/components/FundamentalsPanel.tsx。
library;

import 'package:flutter/material.dart';

import '../../data/market_repository.dart';
import '../../data/symbol_utils.dart';
import '../../models/models.dart';
import '../../theme/app_theme.dart';
import '../../utils/format.dart';

class FundamentalsSection extends StatefulWidget {
  final MarketRepository repository;
  final String symbol;

  const FundamentalsSection({
    super.key,
    required this.repository,
    required this.symbol,
  });

  @override
  State<FundamentalsSection> createState() => _FundamentalsSectionState();
}

class _FundamentalsSectionState extends State<FundamentalsSection> {
  Fundamentals? _data;
  String _error = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FundamentalsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.symbol != widget.symbol) _load();
  }

  Future<void> _load() async {
    if (!isAShareSymbol(widget.symbol)) {
      setState(() {
        _data = null;
        _error = '';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    final symbol = widget.symbol;
    try {
      final data = await widget.repository.fundamentals(symbol);
      if (!mounted || symbol != widget.symbol) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (exc) {
      if (!mounted || symbol != widget.symbol) return;
      setState(() {
        _data = null;
        _error = normalizeError(exc);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // 非 A 股（理论上不该出现）直接不渲染
    if (!isAShareSymbol(widget.symbol)) return const SizedBox.shrink();

    final data = _data;
    final latest = data?.latestReport;
    final valuation = data?.valuation;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 14),
        const _SectionTitle('财务概览'),
        if (_loading) const _Hint('加载中…'),
        if (_error.isNotEmpty) const SizedBox(height: 6),
        if (_error.isNotEmpty) _Hint(_error, warn: true),
        if (data != null) ...[
          const SizedBox(height: 6),
          _kvGrid([
            ('市盈率(动)', formatNumber(valuation?.pe)),
            ('市盈率(TTM)', formatNumber(valuation?.peTtm)),
            ('市净率', formatNumber(valuation?.pb)),
            ('总市值', formatNumber(valuation?.marketCap)),
            ('流通市值', formatNumber(valuation?.floatMarketCap)),
            ('每股净资产', formatNumber(latest?.bps)),
          ]),
          if (latest != null) ...[
            const SizedBox(height: 12),
            _SectionTitle(
              '最新业绩 · ${latest.label}',
              trailing: latest.noticeDate.isEmpty
                  ? null
                  : '公告 ${latest.noticeDate}',
            ),
            const SizedBox(height: 6),
            _kvGrid([
              ('营业总收入', formatNumber(latest.revenue)),
              ('营收同比', formatPercent(latest.revenueYoy)),
              ('归母净利润', formatNumber(latest.parentNetprofit)),
              ('归母同比', formatPercent(latest.parentNetprofitYoy)),
              ('扣非归母', formatNumber(latest.deductParentNetprofit)),
              ('净利润', formatNumber(latest.netprofit)),
              ('每股收益', formatNumber(latest.eps)),
              ('扣非每股收益', formatNumber(latest.deductEps)),
              ('净资产收益率', formatPercent(latest.roe)),
              ('销售毛利率', formatPercent(latest.grossMargin)),
              ('每股经营现金流', formatNumber(latest.operatingCashflowPs)),
              ('利润总额', formatNumber(latest.totalProfit)),
            ]),
          ],
          if (data.reports.length > 1) ...[
            const SizedBox(height: 12),
            const _SectionTitle('历史业绩'),
            const SizedBox(height: 4),
            _reportTable(data.reports),
          ],
          const SizedBox(height: 12),
          const _SectionTitle('分红方案'),
          const SizedBox(height: 4),
          if (data.dividends.isEmpty)
            const _Hint('暂无分红记录')
          else
            _dividendList(data.dividends),
          if (data.warnings.isNotEmpty) ...[
            const SizedBox(height: 6),
            _Hint(data.warnings.join('；'), warn: true),
          ],
        ],
      ],
    );
  }

  static const _reportColumns = [
    ('报告期', 106.0),
    ('营收', 72.0),
    ('营收同比', 74.0),
    ('归母净利润', 84.0),
    ('归母同比', 74.0),
    ('净利润', 72.0),
    ('EPS', 54.0),
    ('ROE', 62.0),
  ];

  Widget _reportTable(List<FundamentalReport> reports) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              for (final (label, width) in _reportColumns)
                SizedBox(
                  width: width,
                  child: Text(label,
                      style: mono(
                          size: FontSize.legend,
                          color: AppColors.textMuted,
                          weight: FontWeight.w600)),
                ),
            ],
          ),
          const SizedBox(height: 2),
          for (final report in reports)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  _cell(report.label, _reportColumns[0].$2),
                  _cell(formatNumber(report.revenue), _reportColumns[1].$2),
                  _cell(formatPercent(report.revenueYoy), _reportColumns[2].$2,
                      tone: report.revenueYoy),
                  _cell(formatNumber(report.parentNetprofit),
                      _reportColumns[3].$2),
                  _cell(formatPercent(report.parentNetprofitYoy),
                      _reportColumns[4].$2,
                      tone: report.parentNetprofitYoy),
                  _cell(formatNumber(report.netprofit), _reportColumns[5].$2),
                  _cell(formatNumber(report.eps), _reportColumns[6].$2),
                  _cell(formatPercent(report.roe), _reportColumns[7].$2),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _cell(String text, double width, {double? tone}) {
    return SizedBox(
      width: width,
      child: Text(
        text,
        overflow: TextOverflow.ellipsis,
        style: mono(size: FontSize.tableNumber, color: _toneColor(tone)),
      ),
    );
  }

  static Color _toneColor(double? value) {
    if (value == null || value.isNaN) return AppColors.text;
    return value >= 0 ? AppColors.rise : AppColors.fall;
  }

  Widget _dividendList(List<FundamentalDividend> dividends) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final item in dividends)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      item.reportDate.isEmpty ? '-' : item.reportDate,
                      style: mono(
                          size: FontSize.tableNumber,
                          color: AppColors.textMuted),
                    ),
                    const SizedBox(width: 8),
                    if (item.progress.isNotEmpty)
                      Text(item.progress,
                          style: const TextStyle(
                              fontSize: FontSize.legend,
                              color: AppColors.textFaint)),
                    const Spacer(),
                    if (item.dividendRatio != null)
                      Text('股息率 ${formatPercent(item.dividendRatio! * 100)}',
                          style: mono(
                              size: FontSize.tableNumber,
                              color: AppColors.warn)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  item.plan.isEmpty ? '-' : item.plan,
                  style: const TextStyle(
                      fontSize: FontSize.body, color: AppColors.text),
                ),
                if (item.exDividendDate.isNotEmpty)
                  Text('除权除息日 ${item.exDividendDate}',
                      style: mono(
                          size: FontSize.legend, color: AppColors.textFaint)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _kvGrid(List<(String, String)> items) {
    return Wrap(
      runSpacing: 6,
      children: [
        for (final (label, value) in items)
          FractionallySizedBox(
            widthFactor: 0.5,
            child: Row(
              children: [
                Text('$label ',
                    style: const TextStyle(
                        fontSize: FontSize.legend, color: AppColors.textFaint)),
                Expanded(
                  child: Text(value,
                      overflow: TextOverflow.ellipsis,
                      style: mono(size: FontSize.tableNumber, color: AppColors.text)),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String? trailing;

  const _SectionTitle(this.title, {this.trailing});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(title,
              style: const TextStyle(
                  fontSize: FontSize.secondaryNumber,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text)),
        ),
        if (trailing != null)
          Text(trailing!,
              style:
                  mono(size: FontSize.legend, color: AppColors.textFaint)),
      ],
    );
  }
}

class _Hint extends StatelessWidget {
  final String text;
  final bool warn;

  const _Hint(this.text, {this.warn = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
          fontSize: FontSize.body,
          color: warn ? AppColors.warn : AppColors.textFaint),
    );
  }
}
