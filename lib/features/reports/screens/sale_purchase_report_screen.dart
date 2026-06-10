import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/report_models.dart';
import '../repositories/reports_repository.dart';
import '../services/report_export_service.dart';
import '../widgets/date_range_bar.dart';
import '../widgets/report_widgets.dart';

/// Reports 2 & 3 — Sale Report / Purchase Report. Same layout, switched by
/// [isPurchase]. Summary bar shows total, received/paid, and outstanding.
class SalePurchaseReportScreen extends StatefulWidget {
  final bool isPurchase;
  const SalePurchaseReportScreen({super.key, required this.isPurchase});

  @override
  State<SalePurchaseReportScreen> createState() =>
      _SalePurchaseReportScreenState();
}

class _SalePurchaseReportScreenState extends State<SalePurchaseReportScreen> {
  final _repo = ReportsRepository();
  DateRange _range = DateRange.thisMonth();
  late Future<List<TxnReportRow>> _future = _load();

  bool get _isPurchase => widget.isPurchase;
  String get _type => _isPurchase ? 'purchase' : 'sale';
  String get _title => _isPurchase ? 'Purchase Report' : 'Sale Report';

  Future<List<TxnReportRow>> _load() =>
      _repo.transactionsByType(_type, _range);

  void _onRange(DateRange r) => setState(() {
        _range = r;
        _future = _load();
      });

  Future<ReportData> _buildExport(List<TxnReportRow> rows) async {
    final total = rows.fold<double>(0, (s, r) => s + r.total);
    final settled = rows.fold<double>(0, (s, r) => s + r.paid);
    final outstanding = rows.fold<double>(0, (s, r) => s + r.balance);
    return ReportData(
      title: _title,
      subtitle:
          '${Formatters.dateShort(_range.start)} — ${Formatters.dateShort(_range.end)}',
      headers: const ['Date', 'Number', 'Party', 'Total', 'Settled', 'Balance'],
      rightAlign: const [false, false, false, true, true, true],
      rows: [
        for (final r in rows)
          [
            Formatters.date(r.date),
            r.number,
            r.partyName ?? '-',
            Formatters.currency(r.total),
            Formatters.currency(r.paid),
            Formatters.currency(r.balance),
          ],
      ],
      summary: [
        MapEntry(_isPurchase ? 'Total Purchase' : 'Total Sale',
            Formatters.currency(total)),
        MapEntry(_isPurchase ? 'Total Paid' : 'Total Received',
            Formatters.currency(settled)),
        MapEntry(_isPurchase ? 'Total Payable' : 'Total Outstanding',
            Formatters.currency(outstanding)),
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
      body: Column(
        children: [
          DateRangeBar(initialRange: _range, onChanged: _onRange),
          const Divider(height: 1),
          Expanded(
            child: FutureBuilder<List<TxnReportRow>>(
              future: _future,
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final rows = snap.data!;
                final total = rows.fold<double>(0, (s, r) => s + r.total);
                final settled = rows.fold<double>(0, (s, r) => s + r.paid);
                final outstanding =
                    rows.fold<double>(0, (s, r) => s + r.balance);

                return Column(
                  children: [
                    SummaryBar(metrics: [
                      (
                        label: _isPurchase ? 'Purchase' : 'Sale',
                        value: Formatters.currency(total),
                        color: AppColors.primary
                      ),
                      (
                        label: _isPurchase ? 'Paid' : 'Received',
                        value: Formatters.currency(settled),
                        color: AppColors.income
                      ),
                      (
                        label: _isPurchase ? 'Payable' : 'Outstanding',
                        value: Formatters.currency(outstanding),
                        color: AppColors.expense
                      ),
                    ]),
                    Expanded(
                      child: rows.isEmpty
                          ? const ReportEmpty()
                          : ListView.separated(
                              itemCount: rows.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) => _row(rows[i]),
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
      subtitle: Text(
          '${r.partyName ?? '-'}  ·  ${Formatters.date(r.date)}',
          style: const TextStyle(fontSize: 12)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Formatters.currency(r.total),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(
            r.balance > 0
                ? 'Due ${Formatters.currency(r.balance)}'
                : 'Settled',
            style: TextStyle(
                fontSize: 11,
                color: r.balance > 0 ? AppColors.expense : AppColors.income),
          ),
        ],
      ),
    );
  }
}
