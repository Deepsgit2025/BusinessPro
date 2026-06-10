import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/item.dart';
import '../models/item_category.dart';
import '../models/item_unit.dart';
import '../models/tax_rate.dart';
import '../models/unit.dart';
import '../repositories/category_repository.dart';
import '../repositories/item_repository.dart';
import '../repositories/item_unit_repository.dart';
import '../repositories/tax_rate_repository.dart';
import '../repositories/unit_repository.dart';

final itemRepositoryProvider = Provider<ItemRepository>((ref) => ItemRepository());
final categoryRepositoryProvider = Provider<CategoryRepository>((ref) => CategoryRepository());
final unitRepositoryProvider = Provider<UnitRepository>((ref) => UnitRepository());
final taxRateRepositoryProvider = Provider<TaxRateRepository>((ref) => TaxRateRepository());
final itemUnitRepositoryProvider =
    Provider<ItemUnitRepository>((ref) => ItemUnitRepository());

/// Current item-list filters. categoryId null ⇒ All.
class ItemFilter {
  final int? categoryId;
  final String search;
  const ItemFilter({this.categoryId, this.search = ''});

  ItemFilter copyWith({Object? categoryId = _unset, String? search}) =>
      ItemFilter(
        categoryId: categoryId == _unset ? this.categoryId : categoryId as int?,
        search: search ?? this.search,
      );

  static const _unset = Object();
}

final itemFilterProvider = StateProvider<ItemFilter>((ref) => const ItemFilter());

final itemListProvider = FutureProvider<List<Item>>((ref) async {
  final filter = ref.watch(itemFilterProvider);
  final repo = ref.watch(itemRepositoryProvider);
  return repo.getItems(categoryId: filter.categoryId, search: filter.search);
});

final itemDetailProvider = FutureProvider.family<Item?, int>((ref, id) async {
  final repo = ref.watch(itemRepositoryProvider);
  return repo.getById(id);
});

final itemHistoryProvider =
    FutureProvider.family<List<Map<String, dynamic>>, int>((ref, id) async {
  final repo = ref.watch(itemRepositoryProvider);
  return repo.stockHistory(id);
});

/// All selling-unit tiers for an item (base unit first), smallest packing up.
final itemUnitsProvider =
    FutureProvider.family<List<ItemUnit>, int>((ref, itemId) async {
  final repo = ref.watch(itemUnitRepositoryProvider);
  return repo.getItemUnits(itemId);
});

/// Master data used by the add/edit form and category management.
final categoriesProvider = FutureProvider<List<ItemCategory>>((ref) async {
  final repo = ref.watch(categoryRepositoryProvider);
  return repo.getCategories();
});

final unitsProvider = FutureProvider<List<Unit>>((ref) async {
  final repo = ref.watch(unitRepositoryProvider);
  return repo.getUnits();
});

final taxRatesProvider = FutureProvider<List<TaxRate>>((ref) async {
  final repo = ref.watch(taxRateRepositoryProvider);
  return repo.getTaxRates();
});
