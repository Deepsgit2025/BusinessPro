import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/report_models.dart';
import '../repositories/reports_repository.dart';
import '../services/report_export_service.dart';
import '../widgets/date_range_bar.dart';
import '../widgets/report_widgets.dart';

/// Report 9 — Expense Report. Expenses grouped by category with a pie chart and
/// a per-category list below.
class ExpenseReportScreen extends StatefulWidget {
  const ExpenseReportScreen({super.key});

  @override
  State<ExpenseReportScreen> createState() => _ExpenseReportScreenState();
}

class _ExpenseReportScreenState extends State<ExpenseReportScreen> {
  final _repo = ReportsRepository();
  DateRange _range = DateRange.thisMonth();
  late Future<List<ExpenseCategoryRow>> _future = _repo.expenseByCategory(_range);

  // A fixed palette cycled across categories for both the pie and the list dots.
  static const _palette = [
    Color(0xFF2E7D32), Color(0xFF1565C0), Color(0xFFF57F17),
    Color(0xFFD32F2F), Color(0xFF6A1B9A), Color(0xFF00838F),
    Color(0xFF558B2F), Color(0xFFEF6C00), Color(0xFFAD1457),
  ];

  void _onRange(DateRange r) => setState(() {
        _range = r;
        _future = _repo.expenseByCategory(_range);
      });

  Future<ReportData> _buildExport(List<ExpenseCategoryRow> rows) async {
    final total = rows.fold<double>(0, (s, r) => s + r.total);
    return ReportData(
      title: 'Expense Report',
      subtitle:
          '${Formatters.dateShort(_range.start)} — ${Formatters.dateShort(_range.end)}',
      headers: const ['Category', 'Count', 'Amount', 'Share'],
      rightAlign: const [false, true, true, true],
      rows: [
        for (final r in rows)
          [
            r.categoryName,
            '${r.count}',
            Formatters.currency(r.total),
            total == 0 ? '0%' : '${(r.total / total * 100).toStringAsFixed(1)}%',
          ],
      ],
      summary: [MapEntry('Total Expense', Formatters.currency(total))],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Expense Report'),
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
            child: FutureBuilder<List<ExpenseCategoryRow>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return const ReportEmpty(message: 'No expenses in this period.');
                }
                final total = rows.fold<double>(0, (s, r) => s + r.total);
                return ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    SizedBox(height: 200, child: _pie(rows, total)),
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppColors.expense.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Total Expense',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          Text(Formatters.currency(total),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.expense)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < rows.length; i++)
                      _legendRow(rows[i], _palette[i % _palette.length], total),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _pie(List<ExpenseCategoryRow> rows, double total) {
    if (total == 0) return const ReportEmpty();
    return PieChart(
      PieChartData(
        sectionsSpace: 2,
        centerSpaceRadius: 48,
        sections: [
          for (var i = 0; i < rows.length; i++)
            PieChartSectionData(
              value: rows[i].total,
              color: _palette[i % _palette.length],
              radius: 50,
              title: '${(rows[i].total / total * 100).round()}%',
              titleStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Colors.white),
            ),
        ],
      ),
    );
  }

  Widget _legendRow(ExpenseCategoryRow r, Color color, double total) {
    final pct = total == 0 ? 0 : (r.total / total * 100);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(width: 12, height: 12,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(3))),
          const SizedBox(width: 10),
          Expanded(
            child: Text(r.categoryName,
                style: const TextStyle(fontSize: 14)),
          ),
          Text('${r.count} · ${pct.toStringAsFixed(1)}%',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(width: 12),
          Text(Formatters.currency(r.total),
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
