/// Summary data for the Item Journey header cards. Read-only.
class InventoryHeader {
  final String name;
  final double currentStock;
  final double minStockLevel;
  final double openingStock;
  final String? baseUnit;
  final double basePurchasePrice;
  final DateTime? createdAt;

  const InventoryHeader({
    required this.name,
    this.currentStock = 0,
    this.minStockLevel = 0,
    this.openingStock = 0,
    this.baseUnit,
    this.basePurchasePrice = 0,
    this.createdAt,
  });

  bool get isOutOfStock => currentStock <= 0;
  bool get isLowStock =>
      !isOutOfStock && minStockLevel > 0 && currentStock <= minStockLevel;

  /// Stock valued at the base-unit purchase price. Never negative: when stock
  /// is negative (data inconsistency) the value floors at 0 rather than showing
  /// a misleading "−₹0.00".
  double get stockValue {
    if (currentStock <= 0 || basePurchasePrice <= 0) return 0;
    return currentStock * basePurchasePrice;
  }

  factory InventoryHeader.fromMap(Map<String, dynamic> m) {
    final created = m['created_at'] as String?;
    // Prefer the base unit's purchase price; fall back to the items row when the
    // base tier has none (older items only carry a price on the items row).
    final basePrice = (m['purchase_price'] as num?)?.toDouble() ?? 0;
    final itemPrice = (m['item_purchase_price'] as num?)?.toDouble() ?? 0;
    return InventoryHeader(
      name: (m['name'] as String?) ?? '',
      currentStock: (m['current_stock'] as num?)?.toDouble() ?? 0,
      minStockLevel: (m['min_stock_level'] as num?)?.toDouble() ?? 0,
      openingStock: (m['opening_stock'] as num?)?.toDouble() ?? 0,
      baseUnit: m['base_unit'] as String?,
      basePurchasePrice: basePrice > 0 ? basePrice : itemPrice,
      createdAt:
          (created == null || created.isEmpty) ? null : DateTime.tryParse(created),
    );
  }
}
