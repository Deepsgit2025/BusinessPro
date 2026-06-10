import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/item.dart';
import '../models/item_unit.dart';
import '../providers/item_providers.dart';
import 'add_edit_item_screen.dart';

/// Read-only view of a single item: header, stock card, transaction history.
class ItemDetailScreen extends ConsumerWidget {
  final int itemId;
  const ItemDetailScreen({super.key, required this.itemId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final itemAsync = ref.watch(itemDetailProvider(itemId));

    return itemAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(appBar: AppBar(), body: Center(child: Text('Error: $e'))),
      data: (item) {
        if (item == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('Item not found')));
        }
        return _ItemDetailView(item: item);
      },
    );
  }
}

class _ItemDetailView extends ConsumerWidget {
  final Item item;
  const _ItemDetailView({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(itemHistoryProvider(item.id!));

    return Scaffold(
      appBar: AppBar(
        title: Text(item.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => AddEditItemScreen(item: item)),
              );
              ref.invalidate(itemDetailProvider(item.id!));
              ref.invalidate(itemHistoryProvider(item.id!));
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _HeaderCard(item: item),
          const SizedBox(height: 12),
          _PricingTiersCard(item: item),
          if (item.isProduct) ...[
            const SizedBox(height: 12),
            _StockCard(item: item),
          ],
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 4),
            child: Text('Transaction History',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          historyAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('Error: $e'),
            data: (history) {
              if (history.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(
                    child: Text('No transactions for this item yet',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ),
                );
              }
              return Column(
                children: history.map((h) {
                  final type = (h['transaction_type'] as String?) ?? '';
                  final qty = (h['quantity'] as num?)?.toDouble() ?? 0;
                  final price = (h['unit_price'] as num?)?.toDouble() ?? 0;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      dense: true,
                      title: Text(h['transaction_number']?.toString() ?? _typeLabel(type)),
                      subtitle: Text(
                          '${_typeLabel(type)} • ${Formatters.date(h['transaction_date'] as String?)}'),
                      trailing: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('${Formatters.qty(qty)} × ${Formatters.currency(price)}',
                              style: const TextStyle(fontSize: 12)),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              );
            },
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final Item item;
  const _HeaderCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (item.categoryName != null && item.categoryName!.isNotEmpty)
                            item.categoryName,
                          item.isProduct ? 'Product' : 'Service',
                        ].whereType<String>().join(' • '),
                        style: const TextStyle(
                            color: AppColors.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(item.isProduct ? 'Product' : 'Service',
                      style: const TextStyle(
                          color: AppColors.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const Divider(height: 24),
            Text('Sale Price',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
            Text(Formatters.currency(item.salePrice),
                style: const TextStyle(
                    color: AppColors.income,
                    fontSize: 24,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                if (item.purchasePrice > 0)
                  Expanded(
                      child: _miniStat('Purchase', Formatters.currency(item.purchasePrice))),
                if (item.mrp > 0) Expanded(child: _miniStat('MRP', Formatters.currency(item.mrp))),
                if (item.taxName != null && item.taxName!.isNotEmpty)
                  Expanded(child: _miniStat('Tax', item.taxName!)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _miniStat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textHint, fontSize: 11)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      );
}

/// Pricing-tiers table plus equivalent-units breakdown (for physical counting).
class _PricingTiersCard extends ConsumerWidget {
  final Item item;
  const _PricingTiersCard({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiersAsync = ref.watch(itemUnitsProvider(item.id!));
    return tiersAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (e, st) => const SizedBox.shrink(),
      data: (tiers) {
        if (tiers.isEmpty) return const SizedBox.shrink();
        final base = tiers.firstWhere((t) => t.isBaseUnit, orElse: () => tiers.first);
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('PRICING TIERS',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                        color: AppColors.textSecondary)),
                const SizedBox(height: 8),
                _tierHeader(),
                const Divider(height: 12),
                ...tiers.map((t) => _tierRow(t, base.unitName)),
                if (item.isProduct && tiers.length > 1) ...[
                  const SizedBox(height: 16),
                  const Text('EQUIVALENT UNITS',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  Text(
                    tiers
                        .map((t) {
                          final eq = t.conversionFactor > 0
                              ? item.currentStock / t.conversionFactor
                              : 0;
                          return '≈ ${Formatters.qty(_round1(eq))} ${t.unitName}';
                        })
                        .join('   |   '),
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  static num _round1(num v) => (v * 10).round() / 10;

  Widget _tierHeader() => const Row(
        children: [
          Expanded(flex: 3, child: _Th('Unit')),
          Expanded(flex: 3, child: _Th('Contains')),
          Expanded(flex: 2, child: _Th('Sale ₹', end: true)),
          Expanded(flex: 2, child: _Th('Buy ₹', end: true)),
        ],
      );

  Widget _tierRow(ItemUnit t, String baseName) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(t.unitName, style: const TextStyle(fontSize: 13)),
            ),
            Expanded(
              flex: 3,
              child: Text(
                t.isBaseUnit
                    ? '—'
                    : '${Formatters.qty(t.conversionFactor)} $baseName',
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(Formatters.currency(t.salePrice),
                  textAlign: TextAlign.end, style: const TextStyle(fontSize: 13)),
            ),
            Expanded(
              flex: 2,
              child: Text(Formatters.currency(t.purchasePrice),
                  textAlign: TextAlign.end,
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            ),
          ],
        ),
      );
}

class _Th extends StatelessWidget {
  final String text;
  final bool end;
  const _Th(this.text, {this.end = false});

  @override
  Widget build(BuildContext context) => Text(
        text,
        textAlign: end ? TextAlign.end : TextAlign.start,
        style: const TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textHint),
      );
}

class _StockCard extends StatelessWidget {
  final Item item;
  const _StockCard({required this.item});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (item.isLowStock)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppColors.pending.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: AppColors.pending, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Low stock — below minimum level',
                        style: TextStyle(color: AppColors.pending, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Current Stock',
                          style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
                      Text(
                        Formatters.qty(item.currentStock, item.unitShort),
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: item.isLowStock ? AppColors.expense : AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(child: _stat('Min Level', Formatters.qty(item.minStockLevel))),
                Expanded(child: _stat('Stock Value', Formatters.currency(item.stockValue))),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String label, String value) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: AppColors.textHint, fontSize: 11)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
        ],
      );
}

String _typeLabel(String type) => switch (type) {
      'sale' => 'Sale',
      'sale_return' => 'Sale Return',
      'purchase' => 'Purchase',
      'purchase_return' => 'Purchase Return',
      _ => type,
    };
