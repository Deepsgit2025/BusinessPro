import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/report_models.dart';
import '../repositories/reports_repository.dart';
import '../services/report_export_service.dart';
import '../widgets/date_range_bar.dart';
import '../widgets/report_widgets.dart';

/// Report 4 — Profit & Loss. Summary cards (gross/net profit) plus a 6-month
/// sale-vs-purchase trend chart.
class ProfitLossScreen extends StatefulWidget {
  const ProfitLossScreen({super.key});

  @override
  State<ProfitLossScreen> createState() => _ProfitLossScreenState();
}

class _ProfitLossScreenState extends State<ProfitLossScreen> {
  final _repo = ReportsRepository();
  DateRange _range = DateRange.thisMonth();
  late Future<ProfitLoss> _future = _repo.profitLoss(_range);
  final Future<List<({String label, double sale, double purchase})>> _trend =
      ReportsRepository().monthlyTrend();

  void _onRange(DateRange r) => setState(() {
        _range = r;
        _future = _repo.profitLoss(_range);
      });

  Future<ReportData> _buildExport(ProfitLoss pl) async {
    return ReportData(
      title: 'Profit & Loss',
      subtitle:
          '${Formatters.dateShort(_range.start)} — ${Formatters.dateShort(_range.end)}',
      headers: const ['Particulars', 'Amount'],
      rightAlign: const [false, true],
      rows: [
        ['Total Sale Revenue', Formatters.currency(pl.totalSale)],
        ['Less: Total Purchase Cost', Formatters.currency(pl.totalPurchase)],
        ['Gross Profit', Formatters.currency(pl.grossProfit)],
        ['Add: Other Income', Formatters.currency(pl.totalIncome)],
        ['Less: Total Expenses', Formatters.currency(pl.totalExpense)],
        ['Net Profit', Formatters.currency(pl.netProfit)],
        ['Net Profit %', '${pl.netProfitPct.toStringAsFixed(1)}%'],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profit & Loss'),
        actions: [
          ReportExportButton(
            dataBuilder: () async => _buildExport(await _future),
          ),
        ],
      ),
      body: Column(
        children: [
          DateRangeBar(initialRange: _range, onChanged: _onRange),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<ProfitLoss>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final pl = snap.data!;
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    _summaryCard(pl),
                    const SizedBox(height: 16),
                    _line('Total Sale', pl.totalSale, AppColors.income),
                    _line('Total Purchase', pl.totalPurchase, AppColors.expense),
                    const Divider(),
                    _line('Gross Profit', pl.grossProfit, AppColors.primary,
                        bold: true),
                    _line('Other Income', pl.totalIncome, AppColors.income),
                    _line('Total Expenses', pl.totalExpense, AppColors.expense),
                    const Divider(),
                    _line('Net Profit', pl.netProfit,
                        pl.netProfit >= 0 ? AppColors.income : AppColors.expense,
                        bold: true),
                    const SizedBox(height: 24),
                    const Text('Last 6 Months',
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 12),
                    SizedBox(height: 200, child: _trendChart()),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(ProfitLoss pl) {
    final positive = pl.netProfit >= 0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: positive
              ? [AppColors.primaryDark, AppColors.primary]
              : [const Color(0xFFB71C1C), AppColors.expense],
        ),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(positive ? 'Net Profit' : 'Net Loss',
              style: const TextStyle(color: Colors.white70, fontSize: 13)),
          const SizedBox(height: 6),
          Text(Formatters.currency(pl.netProfit.abs()),
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('Margin: ${pl.netProfitPct.toStringAsFixed(1)}%',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _line(String label, double value, Color color, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: bold ? 15 : 14,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.normal)),
          Text(Formatters.currency(value),
              style: TextStyle(
                  fontSize: bold ? 15 : 14,
                  fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                  color: color)),
        ],
      ),
    );
  }

  Widget _trendChart() {
    return FutureBuilder<List<({String label, double sale, double purchase})>>(
      future: _trend,
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snap.data!;
        if (data.every((d) => d.sale == 0 && d.purchase == 0)) {
          return const ReportEmpty(message: 'No activity in the last 6 months.');
        }
        final maxY = data
            .map((d) => d.sale > d.purchase ? d.sale : d.purchase)
            .fold<double>(0, (m, v) => v > m ? v : m);

        return BarChart(
          BarChartData(
            alignment: BarChartAlignment.spaceAround,
            maxY: maxY == 0 ? 1 : maxY * 1.2,
            barTouchData: BarTouchData(enabled: false),
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              leftTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              topTitles:
                  const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (value, meta) {
                    final i = value.toInt();
                    if (i < 0 || i >= data.length) return const SizedBox();
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(data[i].label,
                          style: const TextStyle(fontSize: 10)),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < data.length; i++)
                BarChartGroupData(x: i, barRods: [
                  BarChartRodData(
                      toY: data[i].sale,
                      color: AppColors.income,
                      width: 7,
                      borderRadius: BorderRadius.circular(2)),
                  BarChartRodData(
                      toY: data[i].purchase,
                      color: AppColors.partial,
                      width: 7,
                      borderRadius: BorderRadius.circular(2)),
                ]),
            ],
          ),
        );
      },
    );
  }
}
