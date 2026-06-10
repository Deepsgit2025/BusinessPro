import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/report_models.dart';
import '../repositories/reports_repository.dart';
import '../services/report_export_service.dart';
import '../widgets/report_widgets.dart';

/// Report 8 — Stock Summary. Every active product with its on-hand quantity and
/// stock value at both cost and sale price. Summary bar totals the values.
class StockSummaryScreen extends StatefulWidget {
  const StockSummaryScreen({super.key});

  @override
  State<StockSummaryScreen> createState() => _StockSummaryScreenState();
}

class _StockSummaryScreenState extends State<StockSummaryScreen> {
  final _repo = ReportsRepository();
  late final Future<List<StockRow>> _future = _repo.stockSummary();

  Future<ReportData> _buildExport(List<StockRow> rows) async {
    final atCost = rows.fold<double>(0, (s, r) => s + r.stockValueAtCost);
    final atSale = rows.fold<double>(0, (s, r) => s + r.stockValueAtSale);
    return ReportData(
      title: 'Stock Summary',
      subtitle: 'As on ${Formatters.dateShort(DateTime.now())}',
      headers: const [
        'Item', 'Category', 'Stock', 'Cost', 'Value (Cost)', 'Value (Sale)'
      ],
      rightAlign: const [false, false, true, true, true, true],
      rows: [
        for (final r in rows)
          [
            r.name,
            r.categoryName ?? '-',
            Formatters.qty(r.currentStock, r.baseUnit),
            Formatters.currency(r.purchasePrice),
            Formatters.currency(r.stockValueAtCost),
            Formatters.currency(r.stockValueAtSale),
          ],
      ],
      summary: [
        MapEntry('Total Items', '${rows.length}'),
        MapEntry('Total Value (Cost)', Formatters.currency(atCost)),
        MapEntry('Total Value (Sale)', Formatters.currency(atSale)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Stock Summary'),
        actions: [
          ReportExportButton(
            dataBuilder: () async => _buildExport(await _future),
          ),
        ],
      ),
      body: FutureBuilder<List<StockRow>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final rows = snap.data!;
          if (rows.isEmpty) {
            return const ReportEmpty(message: 'No products in stock.');
          }
          final atCost = rows.fold<double>(0, (s, r) => s + r.stockValueAtCost);
          final atSale = rows.fold<double>(0, (s, r) => s + r.stockValueAtSale);
          return Column(
            children: [
              SummaryBar(metrics: [
                (label: 'Items', value: '${rows.length}', color: AppColors.primary),
                (label: 'Value (Cost)', value: Formatters.currency(atCost), color: AppColors.partial),
                (label: 'Value (Sale)', value: Formatters.currency(atSale), color: AppColors.income),
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

  Widget _row(StockRow r) {
    final low = r.currentStock <= r.minStockLevel;
    return ListTile(
      dense: true,
      title: Text(r.name, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
          '${r.categoryName ?? 'Uncategorised'}  ·  Cost ${Formatters.currency(r.purchasePrice)}',
          style: const TextStyle(fontSize: 12)),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(Formatters.qty(r.currentStock, r.baseUnit),
              style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: low ? AppColors.expense : AppColors.textPrimary)),
          Text(Formatters.currency(r.stockValueAtCost),
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
