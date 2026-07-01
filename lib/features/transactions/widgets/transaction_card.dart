import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/transaction.dart';
import '../services/document_actions.dart';

/// A single transaction row on a list screen (sale / purchase / estimate).
///
/// When [onPrint] / [onShare] are supplied AND the document type has a PDF
/// representation, a thin Print / Share action row is shown at the bottom of the
/// card. Cards left without those callbacks (or for cash rows like
/// expense / income, which have no PDF) render exactly as before.
class TransactionCard extends StatelessWidget {
  final Transaction txn;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onPrint;
  final VoidCallback? onShare;

  const TransactionCard({
    super.key,
    required this.txn,
    required this.onTap,
    this.onLongPress,
    this.onPrint,
    this.onShare,
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

    // Show the inline Print / Share actions only when the caller wired them up
    // and the document actually has a PDF (cash rows don't).
    final showActions = (onPrint != null || onShare != null) &&
        DocumentActions.canPdf(txn.transactionType);

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
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
                                  decoration: cancelled
                                      ? TextDecoration.lineThrough
                                      : null,
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
                          txn.displayPartyName ?? 'Walk-in / Cash',
                          style: const TextStyle(
                              color: AppColors.textSecondary, fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          Formatters.date(txn.transactionDate),
                          style: const TextStyle(
                              color: AppColors.textHint, fontSize: 11),
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
              if (showActions) _CardActions(onPrint: onPrint, onShare: onShare),
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

/// The thin Print / Share action strip shown at the bottom of a card. Sits
/// under a hairline divider so it reads as a footer, not part of the body.
class _CardActions extends StatelessWidget {
  final VoidCallback? onPrint;
  final VoidCallback? onShare;
  const _CardActions({this.onPrint, this.onShare});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 2),
          child: Divider(height: 1),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (onPrint != null)
              _ActionButton(
                icon: Icons.print_outlined,
                label: 'Print',
                onTap: onPrint!,
              ),
            if (onShare != null)
              _ActionButton(
                icon: Icons.share_outlined,
                label: 'Share',
                onTap: onShare!,
              ),
          ],
        ),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.primary,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
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
