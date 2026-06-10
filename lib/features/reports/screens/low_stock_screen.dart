import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/report_models.dart';
import '../repositories/reports_repository.dart';
import '../services/report_export_service.dart';
import '../widgets/report_widgets.dart';

/// Report 10 — Low Stock. Products at or below their minimum stock level, shown
/// as red warning cards with how many units they are below minimum.
class LowStockScreen extends StatefulWidget {
  const LowStockScreen({super.key});

  @override
  State<LowStockScreen> createState() => _LowStockScreenState();
}

class _LowStockScreenState extends State<LowStockScreen> {
  final _repo = ReportsRepository();
  late final Future<List<StockRow>> _future = _repo.lowStock();

  Future<ReportData> _buildExport(List<StockRow> rows) async {
    return ReportData(
      title: 'Low Stock Report',
      subtitle: 'As on ${Formatters.dateShort(DateTime.now())}',
      headers: const ['Item', 'Category', 'In Stock', 'Min Level', 'Short By'],
      rightAlign: const [false, false, true, true, true],
      rows: [
        for (final r in rows)
          [
            r.name,
            r.categoryName ?? '-',
            Formatters.qty(r.currentStock, r.baseUnit),
            Formatters.qty(r.minStockLevel, r.baseUnit),
            Formatters.qty(
                r.unitsBelowMin < 0 ? 0 : r.unitsBelowMin, r.baseUnit),
          ],
      ],
      summary: [MapEntry('Items Low', '${rows.length}')],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Low Stock'),
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
            return const ReportEmpty(
                message: 'All products are above their minimum level. 🎉');
          }
          return ListView.builder(
            padding: const EdgeInsets.all(12),
            itemCount: rows.length,
            itemBuilder: (_, i) => _card(rows[i]),
          );
        },
      ),
    );
  }

  Widget _card(StockRow r) {
    final short = r.unitsBelowMin < 0 ? 0.0 : r.unitsBelowMin;
    final outOfStock = r.currentStock <= 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.expense.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.expense.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(outOfStock ? Icons.error_outline : Icons.warning_amber_rounded,
              color: AppColors.expense),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.name,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600)),
                Text(r.categoryName ?? 'Uncategorised',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                outOfStock
                    ? 'Out of stock'
                    : '${Formatters.qty(r.currentStock, r.baseUnit)} left',
                style: const TextStyle(
                    fontWeight: FontWeight.w700, color: AppColors.expense),
              ),
              Text('Min ${Formatters.qty(r.minStockLevel, r.baseUnit)}',
                  style: const TextStyle(
                      fontSize: 11, color: AppColors.textSecondary)),
              if (short > 0)
                Text('Short by ${Formatters.qty(short, r.baseUnit)}',
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.expense)),
            ],
          ),
        ],
      ),
    );
  }
}
