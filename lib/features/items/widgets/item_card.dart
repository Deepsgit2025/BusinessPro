import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/item.dart';

/// A single item row on the list screen.
class ItemCard extends StatelessWidget {
  final Item item;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const ItemCard({
    super.key,
    required this.item,
    required this.onTap,
    this.onLongPress,
  });

  /// Single price, or a low–high range when the item has multiple unit tiers.
  String _priceLabel(Item item) {
    if (item.hasMultipleTiers &&
        item.minTierPrice != null &&
        item.maxTierPrice != null &&
        item.minTierPrice != item.maxTierPrice) {
      return '${Formatters.currency(item.minTierPrice!)}'
          ' – ${Formatters.currency(item.maxTierPrice!)}';
    }
    return Formatters.currency(item.salePrice);
  }

  @override
  Widget build(BuildContext context) {
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
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  item.isProduct ? Icons.inventory_2_outlined : Icons.handyman_outlined,
                  color: AppColors.primary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: const TextStyle(
                          fontWeight: FontWeight.bold, fontSize: 15),
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (item.categoryName != null &&
                        item.categoryName!.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(item.categoryName!,
                          style: const TextStyle(
                              color: AppColors.textHint, fontSize: 11)),
                    ],
                    if (item.hasMultipleTiers) ...[
                      const SizedBox(height: 2),
                      Text('${item.tierCount} price tiers',
                          style: const TextStyle(
                              color: AppColors.primary, fontSize: 11)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _priceLabel(item),
                    style: const TextStyle(
                        color: AppColors.income,
                        fontWeight: FontWeight.bold,
                        fontSize: 14),
                  ),
                  const SizedBox(height: 2),
                  if (item.isProduct)
                    Text(
                      Formatters.qty(item.currentStock, item.unitShort),
                      style: TextStyle(
                        fontSize: 11,
                        color: item.isLowStock
                            ? AppColors.expense
                            : AppColors.textSecondary,
                        fontWeight:
                            item.isLowStock ? FontWeight.w600 : FontWeight.normal,
                      ),
                    )
                  else
                    const Text('Service',
                        style: TextStyle(
                            fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
