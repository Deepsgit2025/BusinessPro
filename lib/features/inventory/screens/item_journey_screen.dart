import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/inventory_header.dart';
import '../models/journey_entry.dart';
import '../providers/inventory_providers.dart';
import '../widgets/journey_entry_card.dart';

/// Per-item stock journey: header summary + a date-grouped timeline of
/// purchases, sales and returns (newest first). Read-only.
class ItemJourneyScreen extends ConsumerWidget {
  final int itemId;
  final String itemName;

  const ItemJourneyScreen({
    super.key,
    required this.itemId,
    required this.itemName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final headerAsync = ref.watch(inventoryHeaderProvider(itemId));
    final journeyAsync = ref.watch(inventoryJourneyProvider(itemId));
    final filter = ref.watch(journeyDateFilterProvider(itemId));

    return Scaffold(
      appBar: AppBar(
        title: Text(itemName),
        actions: [
          IconButton(
            icon: const Icon(Icons.calendar_today_outlined),
            onPressed: () => _pickDateRange(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          headerAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (e, st) => const SizedBox.shrink(),
            data: (h) =>
                h == null ? const SizedBox.shrink() : _HeaderCards(header: h),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: InkWell(
                onTap: () => _pickDateRange(context, ref),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Date: ',
                          style: TextStyle(color: AppColors.textSecondary)),
                      Text(filter.label,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const Icon(Icons.arrow_drop_down),
                    ],
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: journeyAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (entries) {
                if (entries.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text('No stock movement in this period',
                          style: TextStyle(color: AppColors.textSecondary)),
                    ),
                  );
                }
                return _JourneyList(
                  entries: entries,
                  baseUnit: headerAsync.valueOrNull?.baseUnit,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickDateRange(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(journeyDateFilterProvider(itemId).notifier);
    final choice = await showModalBottomSheet<DateRangeKind>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final kind in DateRangeKind.values)
              ListTile(
                title: Text(_kindLabel(kind)),
                onTap: () => Navigator.pop(ctx, kind),
              ),
          ],
        ),
      ),
    );
    if (choice == null) return;

    if (choice == DateRangeKind.custom) {
      if (!context.mounted) return;
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2000),
        lastDate: DateTime.now(),
      );
      if (range == null) return;
      notifier.state = JourneyDateFilter(
        kind: DateRangeKind.custom,
        customFrom: range.start,
        customTo: range.end,
      );
    } else {
      notifier.state = JourneyDateFilter(kind: choice);
    }
  }

  static String _kindLabel(DateRangeKind kind) {
    switch (kind) {
      case DateRangeKind.allTime:
        return 'All Time';
      case DateRangeKind.thisMonth:
        return 'This Month';
      case DateRangeKind.thisYear:
        return 'This Year';
      case DateRangeKind.custom:
        return 'Custom Range';
    }
  }
}

class _HeaderCards extends StatelessWidget {
  final InventoryHeader header;

  const _HeaderCards({required this.header});

  Color _stockBg() {
    if (header.isOutOfStock) return AppColors.expense;
    if (header.isLowStock) return AppColors.pending;
    return AppColors.income;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Row(
        children: [
          Expanded(
            child: _SummaryCard(
              label: 'Current Stock',
              value: Formatters.qty(header.currentStock, header.baseUnit),
              color: _stockBg(),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _SummaryCard(
              label: 'Stock Value',
              value: Formatters.currency(header.stockValue),
              color: AppColors.income,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

/// Renders journey entries grouped under their (newest-first) dates.
class _JourneyList extends StatelessWidget {
  final List<JourneyEntry> entries;
  final String? baseUnit;

  const _JourneyList({required this.entries, this.baseUnit});

  @override
  Widget build(BuildContext context) {
    // Entries arrive newest-first (opening stock last). Insert a date header
    // whenever the day changes.
    final children = <Widget>[];
    DateTime? lastDay;
    for (final e in entries) {
      final day = DateTime(e.date.year, e.date.month, e.date.day);
      if (lastDay == null || day != lastDay) {
        children.add(Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
          child: Text(
            Formatters.date(e.date.toIso8601String()),
            style: const TextStyle(
                fontWeight: FontWeight.w600, color: AppColors.textSecondary),
          ),
        ));
        lastDay = day;
      }
      children.add(JourneyEntryCard(entry: e, baseUnit: baseUnit));
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
      children: children,
    );
  }
}
