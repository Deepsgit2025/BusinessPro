/// A single selling-unit tier for an item. Maps to the `item_units` table.
///
/// Every item has exactly one base-unit row ([isBaseUnit] = true, always
/// [conversionFactor] = 1) that defines the stock-tracking unit. Other tiers
/// describe larger packings via [conversionFactor] — how many BASE units one of
/// this unit contains (e.g. a Bottle of 1000 ml → conversionFactor 1000).
class ItemUnit {
  final int? id;
  final int? itemId;
  final int unitId;
  final String unitName;
  final double conversionFactor;
  final double salePrice;
  final double purchasePrice;
  final double mrp;
  final bool isBaseUnit;
  final bool isDefaultSale;
  final bool isDefaultPurchase;
  final int sortOrder;
  final bool isActive;

  const ItemUnit({
    this.id,
    this.itemId,
    required this.unitId,
    required this.unitName,
    this.conversionFactor = 1,
    this.salePrice = 0,
    this.purchasePrice = 0,
    this.mrp = 0,
    this.isBaseUnit = false,
    this.isDefaultSale = false,
    this.isDefaultPurchase = false,
    this.sortOrder = 0,
    this.isActive = true,
  });

  factory ItemUnit.fromMap(Map<String, dynamic> m) => ItemUnit(
        id: m['id'] as int?,
        itemId: m['item_id'] as int?,
        unitId: (m['unit_id'] as int?) ?? 0,
        unitName: (m['unit_name'] as String?) ?? '',
        conversionFactor: (m['conversion_factor'] as num?)?.toDouble() ?? 1,
        salePrice: (m['sale_price'] as num?)?.toDouble() ?? 0,
        purchasePrice: (m['purchase_price'] as num?)?.toDouble() ?? 0,
        mrp: (m['mrp'] as num?)?.toDouble() ?? 0,
        isBaseUnit: ((m['is_base_unit'] as int?) ?? 0) == 1,
        isDefaultSale: ((m['is_default_sale'] as int?) ?? 0) == 1,
        isDefaultPurchase: ((m['is_default_purchase'] as int?) ?? 0) == 1,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
      );

  /// Column map for insert/update. [itemId] is included only when set so the
  /// repository can attach it when inserting tiers for a freshly created item.
  Map<String, dynamic> toMap() => {
        if (itemId != null) 'item_id': itemId,
        'unit_id': unitId,
        'unit_name': unitName,
        'conversion_factor': conversionFactor,
        'sale_price': salePrice,
        'purchase_price': purchasePrice,
        'mrp': mrp,
        'is_base_unit': isBaseUnit ? 1 : 0,
        'is_default_sale': isDefaultSale ? 1 : 0,
        'is_default_purchase': isDefaultPurchase ? 1 : 0,
        'sort_order': sortOrder,
        'is_active': isActive ? 1 : 0,
      };

  ItemUnit copyWith({
    int? id,
    int? itemId,
    int? unitId,
    String? unitName,
    double? conversionFactor,
    double? salePrice,
    double? purchasePrice,
    double? mrp,
    bool? isBaseUnit,
    bool? isDefaultSale,
    bool? isDefaultPurchase,
    int? sortOrder,
    bool? isActive,
  }) =>
      ItemUnit(
        id: id ?? this.id,
        itemId: itemId ?? this.itemId,
        unitId: unitId ?? this.unitId,
        unitName: unitName ?? this.unitName,
        conversionFactor: conversionFactor ?? this.conversionFactor,
        salePrice: salePrice ?? this.salePrice,
        purchasePrice: purchasePrice ?? this.purchasePrice,
        mrp: mrp ?? this.mrp,
        isBaseUnit: isBaseUnit ?? this.isBaseUnit,
        isDefaultSale: isDefaultSale ?? this.isDefaultSale,
        isDefaultPurchase: isDefaultPurchase ?? this.isDefaultPurchase,
        sortOrder: sortOrder ?? this.sortOrder,
        isActive: isActive ?? this.isActive,
      );
}
