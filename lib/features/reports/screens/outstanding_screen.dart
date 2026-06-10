import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/report_models.dart';
import '../repositories/reports_repository.dart';
import '../services/report_export_service.dart';
import '../widgets/report_widgets.dart';

/// Reports 6 & 7 — Outstanding Receivables / Payables. Switched by [isPayable].
/// One row per party with the total outstanding and aging buckets
/// (0-30 / 31-60 / 60+ days), colour-coded green / amber / red.
class OutstandingScreen extends StatefulWidget {
  final bool isPayable;
  const OutstandingScreen({super.key, required this.isPayable});

  @override
  State<OutstandingScreen> createState() => _OutstandingScreenState();
}

class _OutstandingScreenState extends State<OutstandingScreen> {
  final _repo = ReportsRepository();
  late final Future<List<OutstandingRow>> _future =
      _repo.outstanding(widget.isPayable ? 'purchase' : 'sale');

  String get _title =>
      widget.isPayable ? 'Outstanding Payables' : 'Outstanding Receivables';

  Future<ReportData> _buildExport(List<OutstandingRow> rows) async {
    final total = rows.fold<double>(0, (s, r) => s + r.totalOutstanding);
    return ReportData(
      title: _title,
      subtitle: 'As on ${Formatters.dateShort(DateTime.now())}',
      headers: const [
        'Party', 'Invoices', '0-30', '31-60', '60+', 'Total'
      ],
      rightAlign: const [false, true, true, true, true, true],
      rows: [
        for (final r in rows)
          [
            r.partyName,
            '${r.invoiceCount}',
            Formatters.currency(r.bucket0to30),
            Formatters.currency(r.bucket31to60),
            Formatters.currency(r.bucket60plus),
            Formatters.currency(r.totalOutstanding),
          ],
      ],
      summary: [
        MapEntry(widget.isPayable ? 'Total Payable' : 'Total Receivable',
            Formatters.currency(total)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        actions: [
          ReportExportButton(
            dataBuilder: () async => _buildExport(await _future),
          ),
        ],
      ),
      body: FutureBuilder<List<OutstandingRow>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return ReportEmpty(
                message: widget.isPayable
                    ? 'Nothing outstanding to suppliers.'
                    : 'Nothing outstanding from customers.');
          }
          final total =
              rows.fold<double>(0, (s, r) => s + r.totalOutstanding);
          return Column(
            children: [
              SummaryBar(metrics: [
                (
                  label: widget.isPayable ? 'Total Payable' : 'Total Receivable',
                  value: Formatters.currency(total),
                  color: widget.isPayable
                      ? AppColors.expense
                      : AppColors.income
                ),
                (
                  label: 'Parties',
                  value: '${rows.length}',
                  color: AppColors.primary
                ),
              ]),
              Expanded(
                child: ListView.separated(
                  itemCount: rows.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _row(rows[i]),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _row(OutstandingRow r) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(r.partyName,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    Text('${r.invoiceCount} invoice(s)',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              Text(Formatters.currency(r.totalOutstanding),
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: widget.isPayable
                          ? AppColors.expense
                          : AppColors.income)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _bucket('0-30d', r.bucket0to30, AppColors.income),
              const SizedBox(width: 6),
              _bucket('31-60d', r.bucket31to60, AppColors.pending),
              const SizedBox(width: 6),
              _bucket('60+d', r.bucket60plus, AppColors.expense),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bucket(String label, double value, Color color) {
    if (value <= 0) {
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.divider,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 10, color: AppColors.textHint)),
        ),
      );
    }
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          children: [
            Text(label,
                style: TextStyle(fontSize: 10, color: color)),
            Text(Formatters.currency(value),
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: color)),
          ],
        ),
      ),
    );
  }
}
