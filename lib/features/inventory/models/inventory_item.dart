/// A single row on the Inventory list screen. Read-only view data assembled by
/// [InventoryRepository.getItems] — it is never written back to the database.
///
/// Stock figures are in the item's base unit ([baseUnit]). [lastActivity] is the
/// most recent (non-deleted) transaction date touching this item, or null when
/// the item has never been transacted.
class InventoryItem {
  final int id;
  final String name;
  final String? categoryName;
  final String? baseUnit;
  final double currentStock;
  final double minStockLevel;
  final double basePurchasePrice;
  final DateTime? lastActivity;

  const InventoryItem({
    required this.id,
    required this.name,
    this.categoryName,
    this.baseUnit,
    this.currentStock = 0,
    this.minStockLevel = 0,
    this.basePurchasePrice = 0,
    this.lastActivity,
  });

  bool get isOutOfStock => currentStock <= 0;
  bool get isLowStock =>
      !isOutOfStock && minStockLevel > 0 && currentStock <= minStockLevel;

  double get stockValue => currentStock * basePurchasePrice;

  factory InventoryItem.fromMap(Map<String, dynamic> m) {
    final raw = m['last_activity_date'] as String?;
    return InventoryItem(
      id: m['id'] as int,
      name: (m['name'] as String?) ?? '',
      categoryName: m['category_name'] as String?,
      baseUnit: m['base_unit'] as String?,
      currentStock: (m['current_stock'] as num?)?.toDouble() ?? 0,
      minStockLevel: (m['min_stock_level'] as num?)?.toDouble() ?? 0,
      basePurchasePrice: (m['purchase_price'] as num?)?.toDouble() ?? 0,
      lastActivity:
          (raw == null || raw.isEmpty) ? null : DateTime.tryParse(raw),
    );
  }
}
