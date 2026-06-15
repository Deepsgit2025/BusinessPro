import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/inventory_item.dart';

/// A single item row on the Inventory list screen. Tap opens the item journey.
class InventoryItemCard extends StatelessWidget {
  final InventoryItem item;
  final VoidCallback onTap;

  const InventoryItemCard({
    super.key,
    required this.item,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.inventory_2_outlined,
                    color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            item.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (item.categoryName != null &&
                            item.categoryName!.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(item.categoryName!,
                              style: const TextStyle(
                                  color: AppColors.textHint, fontSize: 11)),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Current Stock: '
                      '${Formatters.qty(item.currentStock, item.baseUnit)}',
                      style: const TextStyle(
                          fontSize: 13, color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          'Last activity: ${Formatters.relativeDay(item.lastActivity)}',
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textHint),
                        ),
                        if (item.isOutOfStock || item.isLowStock) ...[
                          const Spacer(),
                          _StatusBadge(
                            label: item.isOutOfStock
                                ? '⚠ Out of Stock'
                                : '⚠ Low Stock',
                            color: item.isOutOfStock
                                ? AppColors.expense
                                : AppColors.pending,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _StatusBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
            fontSize: 11, color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
