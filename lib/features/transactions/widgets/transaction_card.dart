import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/transaction.dart';

/// A single transaction row on a list screen (sale / purchase / estimate).
class TransactionCard extends StatelessWidget {
  final Transaction txn;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const TransactionCard({
    super.key,
    required this.txn,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final cancelled = txn.isCancelled;
    final typeTag = _typeTag(txn.transactionType);
    // Non-billed document types (estimate / challan / sale order) show a
    // document-status label rather than a payment (paid/unpaid) badge.
    final showsDocStatus = const {
      TxnTypes.estimate,
      TxnTypes.deliveryChallan,
      TxnTypes.saleOrder,
      TxnTypes.purchaseOrder,
    }.contains(txn.transactionType);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            txn.transactionNumber,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              decoration:
                                  cancelled ? TextDecoration.lineThrough : null,
                              color: cancelled ? AppColors.textHint : null,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (typeTag != null) _Tag(typeTag.$1, typeTag.$2),
                        if (cancelled) _Tag('Cancelled', AppColors.expense),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      txn.partyName?.trim().isNotEmpty == true
                          ? txn.partyName!
                          : 'Walk-in / Cash',
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      Formatters.date(txn.transactionDate),
                      style: const TextStyle(color: AppColors.textHint, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    Formatters.currency(txn.totalAmount),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                  const SizedBox(height: 4),
                  if (!showsDocStatus) _StatusBadge(txn),
                  if (showsDocStatus)
                    Text(
                      _docStatusLabel(txn.status),
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 11),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _docStatusLabel(String status) => switch (status) {
        'converted' => 'Converted',
        'draft' => 'Draft',
        _ => 'Open',
      };

  /// A (label, colour) tag identifying the document type, or null for a plain
  /// Sale Invoice (the default — left untagged to avoid noise).
  static (String, Color)? _typeTag(String type) => switch (type) {
        TxnTypes.estimate => ('Estimate', AppColors.partial),
        TxnTypes.deliveryChallan => ('Delivery Challan', AppColors.pending),
        TxnTypes.saleOrder => ('Sale Order', AppColors.pending),
        TxnTypes.saleReturn => ('Credit Note', AppColors.expense),
        TxnTypes.paymentIn => ('Payment-In', AppColors.paid),
        TxnTypes.purchaseOrder => ('Purchase Order', AppColors.pending),
        TxnTypes.purchaseReturn => ('Debit Note', AppColors.expense),
        TxnTypes.paymentOut => ('Payment-Out', AppColors.paid),
        TxnTypes.purchase => ('Purchase', AppColors.primary),
        _ => null,
      };
}

/// Payment-status badge with balance-due colour coding.
class _StatusBadge extends StatelessWidget {
  final Transaction txn;
  const _StatusBadge(this.txn);

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (txn.paymentStatus) {
      'paid' => ('Paid', AppColors.paid),
      'partial' => ('Partial', AppColors.partial),
      _ => ('Unpaid', AppColors.expense),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(label,
              style: TextStyle(
                  color: color, fontSize: 10, fontWeight: FontWeight.w600)),
        ),
        if (txn.balanceAmount > 0) ...[
          const SizedBox(height: 2),
          Text('Due ${Formatters.currency(txn.balanceAmount)}',
              style: TextStyle(color: color, fontSize: 10)),
        ],
      ],
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style:
              TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w600)),
    );
  }
}
