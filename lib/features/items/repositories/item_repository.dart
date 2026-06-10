import '../../../core/database/database_helper.dart';
import '../models/item.dart';
import '../models/item_unit.dart';
import 'item_unit_repository.dart';

/// Data access for items. Soft delete only.
class ItemRepository {
  static const _businessId = 1;

  final ItemUnitRepository _units = ItemUnitRepository();

  /// Active items joined with category / unit / tax names, name-sorted.
  /// [categoryId] filters by category; [search] matches name, SKU, or barcode.
  Future<List<Item>> getItems({int? categoryId, String? search}) async {
    final db = await DatabaseHelper.database;

    final where = <String>['i.business_id = ?', 'i.is_active = 1'];
    final args = <Object?>[_businessId];

    if (categoryId != null) {
      where.add('i.category_id = ?');
      args.add(categoryId);
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add('(i.name LIKE ? OR i.sku LIKE ? OR i.barcode LIKE ?)');
      final like = '%${search.trim()}%';
      args..add(like)..add(like)..add(like);
    }

    final rows = await db.rawQuery('''
      SELECT i.*, c.name AS category_name, u.short_name AS unit_short,
        t.name AS tax_name, t.rate AS tax_rate_value,
        iu.tier_count AS tier_count, iu.min_tier_price AS min_tier_price,
        iu.max_tier_price AS max_tier_price
      FROM items i
      LEFT JOIN item_categories c ON c.id = i.category_id
      LEFT JOIN units u ON u.id = i.unit_id
      LEFT JOIN tax_rates t ON t.id = i.tax_rate_id
      LEFT JOIN ($_tierAggSql) iu ON iu.item_id = i.id
      WHERE ${where.join(' AND ')}
      ORDER BY i.name COLLATE NOCASE ASC
    ''', args);

    return rows.map(Item.fromMap).toList();
  }

  /// Per-item tier aggregates (count + sale-price range over active tiers).
  static const _tierAggSql = '''
    SELECT item_id,
      COUNT(*) AS tier_count,
      MIN(sale_price) AS min_tier_price,
      MAX(sale_price) AS max_tier_price
    FROM item_units WHERE is_active = 1 GROUP BY item_id
  ''';

  Future<Item?> getById(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT i.*, c.name AS category_name, u.short_name AS unit_short,
        t.name AS tax_name, t.rate AS tax_rate_value,
        iu.tier_count AS tier_count, iu.min_tier_price AS min_tier_price,
        iu.max_tier_price AS max_tier_price
      FROM items i
      LEFT JOIN item_categories c ON c.id = i.category_id
      LEFT JOIN units u ON u.id = i.unit_id
      LEFT JOIN tax_rates t ON t.id = i.tax_rate_id
      LEFT JOIN ($_tierAggSql) iu ON iu.item_id = i.id
      WHERE i.id = ?
    ''', [id]);
    return rows.isEmpty ? null : Item.fromMap(rows.first);
  }

  /// Inserts a new item. Opening stock seeds current_stock.
  ///
  /// [tiers] is the item's selling-unit set. When supplied, the base tier's
  /// unit / price columns are mirrored onto the items row (so the rest of the
  /// app, which still reads `item.salePrice` / `unit_id`, keeps working) and the
  /// full tier set is written to `item_units`. Omit for callers that don't yet
  /// manage tiers — a single base tier mirroring the item is created.
  Future<int> insert(Item item, {List<ItemUnit>? tiers}) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    final effective = _withMirroredBase(item, tiers);
    final id = await db.insert('items', {
      ...effective.toMap(),
      'current_stock': effective.openingStock,
      'created_at': now,
      'updated_at': now,
    });
    await _units.replaceItemUnits(id, _resolveTiers(effective, tiers));
    return id;
  }

  /// Updates an item. current_stock is deliberately left untouched (driven by
  /// transactions). Logs any sale/purchase/mrp price changes to history.
  /// See [insert] for [tiers] semantics.
  Future<void> update(Item item, {List<ItemUnit>? tiers}) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();

    final existing = await getById(item.id!);
    final effective = _withMirroredBase(item, tiers);
    await db.update(
      'items',
      {...effective.toMap(), 'updated_at': now},
      where: 'id = ?',
      whereArgs: [item.id],
    );

    await _units.replaceItemUnits(item.id!, _resolveTiers(effective, tiers));

    if (existing != null) {
      await _logPriceChange(item.id!, 'sale', existing.salePrice, effective.salePrice);
      await _logPriceChange(item.id!, 'purchase', existing.purchasePrice, effective.purchasePrice);
      await _logPriceChange(item.id!, 'mrp', existing.mrp, effective.mrp);
    }
  }

  /// Returns [item] with its unit/price columns overwritten from the base tier,
  /// keeping the legacy items-row fields in sync with the source-of-truth tier.
  Item _withMirroredBase(Item item, List<ItemUnit>? tiers) {
    if (tiers == null || tiers.isEmpty) return item;
    final base = tiers.firstWhere((t) => t.isBaseUnit, orElse: () => tiers.first);
    return Item(
      id: item.id,
      businessId: item.businessId,
      categoryId: item.categoryId,
      unitId: base.unitId,
      taxRateId: item.taxRateId,
      name: item.name,
      description: item.description,
      sku: item.sku,
      barcode: item.barcode,
      hsnCode: item.hsnCode,
      itemType: item.itemType,
      salePrice: base.salePrice,
      purchasePrice: base.purchasePrice,
      mrp: base.mrp,
      openingStock: item.openingStock,
      currentStock: item.currentStock,
      minStockLevel: item.minStockLevel,
      taxInclusive: item.taxInclusive,
      isActive: item.isActive,
    );
  }

  /// The tier set to persist. Falls back to a single base tier mirroring the
  /// item when no tiers were provided (legacy single-unit path).
  List<ItemUnit> _resolveTiers(Item item, List<ItemUnit>? tiers) {
    if (tiers != null && tiers.isNotEmpty) return tiers;
    return [
      ItemUnit(
        unitId: item.unitId ?? 0,
        unitName: item.unitShort ?? 'unit',
        conversionFactor: 1,
        salePrice: item.salePrice,
        purchasePrice: item.purchasePrice,
        mrp: item.mrp,
        isBaseUnit: true,
        isDefaultSale: true,
        isDefaultPurchase: true,
      ),
    ];
  }

  Future<void> _logPriceChange(int itemId, String type, double oldP, double newP) async {
    if (oldP == newP) return;
    final db = await DatabaseHelper.database;
    await db.insert('item_price_history', {
      'item_id': itemId,
      'price_type': type,
      'old_price': oldP,
      'new_price': newP,
      'changed_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> softDelete(int id) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'items',
      {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> transactionCount(int itemId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS c
      FROM transaction_items ti
      JOIN transactions t ON t.id = ti.transaction_id
      WHERE ti.item_id = ? AND t.is_deleted = 0
    ''', [itemId]);
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Every transaction line this item appeared in, newest first.
  Future<List<Map<String, dynamic>>> stockHistory(int itemId) async {
    final db = await DatabaseHelper.database;
    return db.rawQuery('''
      SELECT t.transaction_date, t.transaction_type, t.transaction_number,
        ti.quantity, ti.unit_price, ti.total_amount
      FROM transaction_items ti
      JOIN transactions t ON t.id = ti.transaction_id
      WHERE ti.item_id = ? AND t.is_deleted = 0
      ORDER BY t.transaction_date DESC, t.id DESC
    ''', [itemId]);
  }
}
