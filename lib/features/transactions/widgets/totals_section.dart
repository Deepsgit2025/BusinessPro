import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../utils/txn_calc.dart';

/// Compact two-column totals strip shown under the billed items, mirroring the
/// Vyapar layout: Total Disc / Total Tax Amt on the first row and Total Qty /
/// Subtotal on the second. Quantity is the sum of line quantities.
class TotalsStrip extends StatelessWidget {
  final TxnTotals totals;
  final double totalQty;
  const TotalsStrip({super.key, required this.totals, required this.totalQty});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _cell('Total Disc', _num(totals.discountAmount))),
              Expanded(child: _cell('Total Tax Amt', _num(totals.taxAmount))),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(child: _cell('Total Qty', _num(totalQty))),
              Expanded(
                  child: _cell('Subtotal', _num(totals.taxableAmount),
                      alignEnd: false)),
            ],
          ),
        ],
      ),
    );
  }

  static String _num(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(1) : v.toStringAsFixed(2);

  Widget _cell(String label, String value, {bool alignEnd = false}) {
    return Row(
      mainAxisAlignment:
          alignEnd ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: [
        Text('$label: ',
            style: const TextStyle(
                fontSize: 13, color: AppColors.textSecondary)),
        Text(value,
            style: const TextStyle(
                fontSize: 13, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// The read-only totals breakdown shared by every transaction screen.
/// CGST/SGST rows show for intra-state; IGST for inter-state. Zero rows for
/// discount / round-off are hidden to keep the panel compact.
class TotalsSection extends StatelessWidget {
  final TxnTotals totals;
  const TotalsSection({super.key, required this.totals});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            _row('Subtotal', totals.subtotal),
            if (totals.discountAmount > 0)
              _row('Discount (-)', -totals.discountAmount, color: AppColors.expense),
            _row('Taxable Amount', totals.taxableAmount),
            if (!totals.interState && totals.taxAmount > 0) ...[
              _row('CGST (+)', totals.cgstAmount),
              _row('SGST (+)', totals.sgstAmount),
            ],
            if (totals.interState && totals.taxAmount > 0)
              _row('IGST (+)', totals.igstAmount),
            if (totals.roundOff != 0)
              _row('Round Off', totals.roundOff),
            const Divider(height: 16),
            _row('Total', totals.total, bold: true, large: true),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, double value,
      {bool bold = false, bool large = false, Color? color}) {
    final style = TextStyle(
      fontSize: large ? 16 : 13,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      color: color ?? (bold ? AppColors.primary : null),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style.copyWith(color: color ?? (bold ? null : AppColors.textSecondary))),
          Text(Formatters.currency(value), style: style),
        ],
      ),
    );
  }
}
