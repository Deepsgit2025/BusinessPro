import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/inventory_header.dart';
import '../models/inventory_item.dart';
import '../models/journey_entry.dart';
import '../repositories/inventory_repository.dart';

final inventoryRepositoryProvider =
    Provider<InventoryRepository>((ref) => InventoryRepository());

// ── List screen state ────────────────────────────────────────────────────────

final inventorySortProvider =
    StateProvider<InventorySort>((ref) => InventorySort.mostActive);

final inventorySearchProvider = StateProvider<String>((ref) => '');

/// Active product items with stock + last-activity. Re-queries when sort or
/// search changes, and is invalidated by [invalidateAllSyncedData] after sync.
final inventoryListProvider = FutureProvider<List<InventoryItem>>((ref) async {
  final sort = ref.watch(inventorySortProvider);
  final search = ref.watch(inventorySearchProvider);
  final repo = ref.watch(inventoryRepositoryProvider);
  return repo.getItems(sort: sort, search: search);
});

// ── Journey screen state ─────────────────────────────────────────────────────

enum DateRangeKind { allTime, thisMonth, thisYear, custom }

/// A resolved date window for the journey query. [from]/[to] are inclusive ISO
/// date strings; All Time uses wide sentinel bounds.
class JourneyDateFilter {
  final DateRangeKind kind;
  final DateTime? customFrom;
  final DateTime? customTo;

  const JourneyDateFilter({
    this.kind = DateRangeKind.allTime,
    this.customFrom,
    this.customTo,
  });

  String get from {
    final now = DateTime.now();
    switch (kind) {
      case DateRangeKind.allTime:
        return '0000-01-01';
      case DateRangeKind.thisMonth:
        return _iso(DateTime(now.year, now.month, 1));
      case DateRangeKind.thisYear:
        return _iso(DateTime(now.year, 1, 1));
      case DateRangeKind.custom:
        return customFrom == null ? '0000-01-01' : _iso(customFrom!);
    }
  }

  String get to {
    switch (kind) {
      case DateRangeKind.custom:
        // End of the chosen day so same-day transactions are included.
        return customTo == null ? '9999-12-31' : '${_iso(customTo!)}T23:59:59';
      default:
        return '9999-12-31';
    }
  }

  String get label {
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

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// Per-item date filter, keyed by item id so each open journey is independent.
final journeyDateFilterProvider =
    StateProvider.family<JourneyDateFilter, int>(
        (ref, itemId) => const JourneyDateFilter());

final inventoryHeaderProvider =
    FutureProvider.family<InventoryHeader?, int>((ref, itemId) async {
  final repo = ref.watch(inventoryRepositoryProvider);
  return repo.getHeader(itemId);
});

/// Journey rows for an item within the active date filter, with the synthetic
/// opening-stock row appended last (oldest) when opening stock > 0 and the row
/// falls inside the selected window.
final inventoryJourneyProvider =
    FutureProvider.family<List<JourneyEntry>, int>((ref, itemId) async {
  final repo = ref.watch(inventoryRepositoryProvider);
  final filter = ref.watch(journeyDateFilterProvider(itemId));

  final entries =
      await repo.getJourney(itemId, from: filter.from, to: filter.to);

  final header = await ref.watch(inventoryHeaderProvider(itemId).future);
  if (header != null && header.openingStock > 0 && header.createdAt != null) {
    final created = header.createdAt!;
    final inRange = _withinFilter(created, filter);
    if (inRange) {
      entries.add(JourneyEntry.opening(
        openingStock: header.openingStock,
        date: created,
      ));
    }
  }
  return entries;
});

bool _withinFilter(DateTime date, JourneyDateFilter filter) {
  final day = DateTime(date.year, date.month, date.day);
  final from = DateTime.tryParse(filter.from);
  if (from != null && day.isBefore(DateTime(from.year, from.month, from.day))) {
    return false;
  }
  final to = DateTime.tryParse(filter.to);
  if (to != null && day.isAfter(DateTime(to.year, to.month, to.day))) {
    return false;
  }
  return true;
}
