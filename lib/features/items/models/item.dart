/// A product or service. Maps to the `items` table.
///
/// The list-screen query joins category / unit / tax names; those denormalised
/// fields ([categoryName], [unitShort], [taxName], [taxRateValue]) are read-only
/// view data and are not written back by [toMap].
class Item {
  final int? id;
  final int businessId;
  final int? categoryId;
  final int? unitId;
  final int? taxRateId;
  final String name;
  final String? description;
  final String? sku;
  final String? barcode;
  final String? hsnCode;
  final String itemType; // 'product' | 'service'
  final double salePrice;
  final double purchasePrice;
  final double mrp;
  final double openingStock;
  final double currentStock;
  final double minStockLevel;
  final bool taxInclusive;
  final bool isActive;

  // Joined view data (not persisted on the items row).
  final String? categoryName;
  final String? unitShort;
  final String? taxName;
  final double? taxRateValue;

  // Tier aggregates from item_units (read-only, populated by list/detail query).
  final int tierCount;
  final double? minTierPrice;
  final double? maxTierPrice;

  const Item({
    this.id,
    this.businessId = 1,
    this.categoryId,
    this.unitId,
    this.taxRateId,
    required this.name,
    this.description,
    this.sku,
    this.barcode,
    this.hsnCode,
    this.itemType = 'product',
    this.salePrice = 0,
    this.purchasePrice = 0,
    this.mrp = 0,
    this.openingStock = 0,
    this.currentStock = 0,
    this.minStockLevel = 0,
    this.taxInclusive = false,
    this.isActive = true,
    this.categoryName,
    this.unitShort,
    this.taxName,
    this.taxRateValue,
    this.tierCount = 0,
    this.minTierPrice,
    this.maxTierPrice,
  });

  bool get isProduct => itemType == 'product';
  bool get isLowStock => isProduct && minStockLevel > 0 && currentStock < minStockLevel;
  double get stockValue => currentStock * purchasePrice;

  /// True when the item sells in more than one unit tier.
  bool get hasMultipleTiers => tierCount > 1;

  factory Item.fromMap(Map<String, dynamic> m) => Item(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        categoryId: m['category_id'] as int?,
        unitId: m['unit_id'] as int?,
        taxRateId: m['tax_rate_id'] as int?,
        name: (m['name'] as String?) ?? '',
        description: m['description'] as String?,
        sku: m['sku'] as String?,
        barcode: m['barcode'] as String?,
        hsnCode: m['hsn_code'] as String?,
        itemType: (m['item_type'] as String?) ?? 'product',
        salePrice: (m['sale_price'] as num?)?.toDouble() ?? 0,
        purchasePrice: (m['purchase_price'] as num?)?.toDouble() ?? 0,
        mrp: (m['mrp'] as num?)?.toDouble() ?? 0,
        openingStock: (m['opening_stock'] as num?)?.toDouble() ?? 0,
        currentStock: (m['current_stock'] as num?)?.toDouble() ?? 0,
        minStockLevel: (m['min_stock_level'] as num?)?.toDouble() ?? 0,
        taxInclusive: ((m['tax_inclusive'] as int?) ?? 0) == 1,
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
        categoryName: m['category_name'] as String?,
        unitShort: m['unit_short'] as String?,
        taxName: m['tax_name'] as String?,
        taxRateValue: (m['tax_rate_value'] as num?)?.toDouble(),
        tierCount: (m['tier_count'] as int?) ?? 0,
        minTierPrice: (m['min_tier_price'] as num?)?.toDouble(),
        maxTierPrice: (m['max_tier_price'] as num?)?.toDouble(),
      );

  /// Column map for insert/update. `current_stock` is handled by the repository
  /// (set to `opening_stock` on insert; left untouched on edit so transactions
  /// keep driving it).
  Map<String, dynamic> toMap() => {
        'business_id': businessId,
        'category_id': categoryId,
        'unit_id': unitId,
        'tax_rate_id': taxRateId,
        'name': name,
        'description': description,
        'sku': sku,
        'barcode': barcode,
        'hsn_code': hsnCode,
        'item_type': itemType,
        'sale_price': salePrice,
        'purchase_price': purchasePrice,
        'mrp': mrp,
        'opening_stock': openingStock,
        'min_stock_level': minStockLevel,
        'tax_inclusive': taxInclusive ? 1 : 0,
        'is_active': isActive ? 1 : 0,
      };
}
