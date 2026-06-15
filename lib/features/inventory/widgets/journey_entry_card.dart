import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/journey_entry.dart';

/// One stock-movement card in the item journey (inline, no navigation).
class JourneyEntryCard extends StatelessWidget {
  final JourneyEntry entry;
  final String? baseUnit;

  const JourneyEntryCard({
    super.key,
    required this.entry,
    this.baseUnit,
  });

  Color get _accent {
    switch (entry.type) {
      case 'opening':
        return AppColors.textSecondary;
      default:
        return entry.isInflow ? AppColors.income : AppColors.expense;
    }
  }

  String get _qtyText {
    final v = entry.signedBaseQty;
    final sign = v >= 0 ? '+' : '−';
    final magnitude = Formatters.qty(v.abs(), baseUnit);
    return '$sign$magnitude';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _TypeTag(label: entry.label, color: _accent),
                const Spacer(),
                Text(
                  _qtyText,
                  style: TextStyle(
                      color: _accent,
                      fontWeight: FontWeight.bold,
                      fontSize: 15),
                ),
              ],
            ),
            if (entry.type == 'opening') ...[
              const SizedBox(height: 6),
              const Text(
                'Initial stock when item was created',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ] else ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  if (entry.partyName != null && entry.partyName!.isNotEmpty)
                    Expanded(
                      child: Text(
                        entry.partyName!,
                        style: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    )
                  else
                    const Spacer(),
                  if (entry.transactionNumber != null &&
                      entry.transactionNumber!.isNotEmpty)
                    Text(
                      entry.transactionNumber!,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textHint),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _lineDetail(),
                style:
                    const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _lineDetail() {
    final qty = Formatters.qty(entry.quantity, entry.unitName);
    return '$qty @ ${Formatters.currency(entry.unitPrice)} each';
  }
}

class _TypeTag extends StatelessWidget {
  final String label;
  final Color color;

  const _TypeTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11, color: color, fontWeight: FontWeight.w700),
      ),
    );
  }
}
