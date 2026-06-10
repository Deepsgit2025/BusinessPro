import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/report_models.dart';
import '../repositories/reports_repository.dart';
import '../services/report_export_service.dart';
import '../widgets/report_widgets.dart';

/// Report 1 — Day Book. Every transaction for a chosen day, grouped by type,
/// with a totals footer. Date picker at the top (defaults to today).
class DayBookScreen extends StatefulWidget {
  const DayBookScreen({super.key});

  @override
  State<DayBookScreen> createState() => _DayBookScreenState();
}

class _DayBookScreenState extends State<DayBookScreen> {
  final _repo = ReportsRepository();
  DateTime _date = DateTime.now();
  late Future<List<TxnReportRow>> _future = _repo.dayBook(_date);

  void _reload() => setState(() => _future = _repo.dayBook(_date));

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2015),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) {
      _date = picked;
      _reload();
    }
  }

  Future<ReportData> _buildExport(List<TxnReportRow> rows) async {
    return ReportData(
      title: 'Day Book',
      subtitle: Formatters.dateShort(_date),
      headers: const ['Number', 'Type', 'Party', 'Total', 'Paid', 'Balance'],
      rightAlign: const [false, false, false, true, true, true],
      rows: [
        for (final r in rows)
          [
            r.number,
            _label(r.type),
            r.partyName ?? '-',
            Formatters.currency(r.total),
            Formatters.currency(r.paid),
            Formatters.currency(r.balance),
          ],
      ],
      summary: [
        MapEntry('Total', Formatters.currency(
            rows.fold<double>(0, (s, r) => s + r.total))),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Day Book'),
        actions: [
          ReportExportButton(
            dataBuilder: () async => _buildExport(await _future),
          ),
        ],
      ),
      body: Column(
        children: [
          InkWell(
            onTap: _pickDate,
            child: Container(
              color: Theme.of(context).cardColor,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today_outlined,
                      size: 18, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Text(Formatters.dateShort(_date),
                      style: const TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  const Text('Change',
                      style: TextStyle(color: AppColors.primary)),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<TxnReportRow>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = snap.data!;
                if (rows.isEmpty) {
                  return const ReportEmpty(
                      message: 'No transactions on this day.');
                }
                // Group by transaction type, preserving query order within.
                final groups = <String, List<TxnReportRow>>{};
                for (final r in rows) {
                  groups.putIfAbsent(r.type, () => []).add(r);
                }
                final total =
                    rows.fold<double>(0, (s, r) => s + r.total);

                return ListView(
                  children: [
                    for (final entry in groups.entries) ...[
                      Container(
                        width: double.infinity,
                        color: AppColors.primary.withValues(alpha: 0.08),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 6),
                        child: Text(_label(entry.key).toUpperCase(),
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: AppColors.primaryDark)),
                      ),
                      for (final r in entry.value) _row(r),
                    ],
                    Container(
                      color: AppColors.primary.withValues(alpha: 0.06),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('Day Total',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                          Text(Formatters.currency(total),
                              style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: AppColors.primary)),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(TxnReportRow r) {
    return ListTile(
      dense: true,
      title: Text(r.number, style: const TextStyle(fontSize: 14)),
      subtitle: Text(r.partyName ?? '-',
          style: const TextStyle(fontSize: 12)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Formatters.currency(r.total),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          if (r.balance > 0)
            Text('Due ${Formatters.currency(r.balance)}',
                style: const TextStyle(fontSize: 11, color: AppColors.expense)),
        ],
      ),
    );
  }

  static String _label(String type) => switch (type) {
        'sale' => 'Sale',
        'sale_return' => 'Sale Return',
        'purchase' => 'Purchase',
        'purchase_return' => 'Purchase Return',
        'expense' => 'Expense',
        'other_income' => 'Income',
        'payment_in' => 'Payment In',
        'payment_out' => 'Payment Out',
        'estimate' => 'Estimate',
        'delivery_challan' => 'Delivery Challan',
        _ => type,
      };
}
