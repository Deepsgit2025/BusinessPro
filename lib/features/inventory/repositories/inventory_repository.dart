import '../../../core/database/database_helper.dart';
import '../models/inventory_header.dart';
import '../models/inventory_item.dart';
import '../models/journey_entry.dart';

/// Sort options for the inventory list.
enum InventorySort { mostActive, alphabetical, lowStockFirst }

/// Read-only data access for the Inventory module. Derives stock movement from
/// the existing items / item_units / transactions / transaction_items tables —
/// it never writes. After a Drive sync merges rows, these queries simply see the
/// merged data (sync remaps UUIDs back to local ids before insert), so no
/// special handling is needed here.
class InventoryRepository {
  static const _businessId = 1;

  /// Transaction types that move stock, in the journey.
  static const _stockTypes =
      "'purchase', 'purchase_return', 'sale', 'sale_return'";

  /// Active product items with current stock, base unit, category and the date
  /// of their most recent (non-deleted) transaction.
  Future<List<InventoryItem>> getItems({
    InventorySort sort = InventorySort.mostActive,
    String? search,
  }) async {
    final db = await DatabaseHelper.database;

    final where = <String>[
      'i.business_id = ?',
      'i.is_active = 1',
      "i.item_type = 'product'",
    ];
    final args = <Object?>[_businessId];

    if (search != null && search.trim().isNotEmpty) {
      where.add('i.name LIKE ?');
      args.add('%${search.trim()}%');
    }

    final rows = await db.rawQuery('''
      SELECT i.id, i.name, i.current_stock, i.min_stock_level,
        c.name AS category_name,
        iu.unit_name AS base_unit, iu.purchase_price AS purchase_price,
        MAX(t.transaction_date) AS last_activity_date
      FROM items i
      LEFT JOIN item_categories c ON c.id = i.category_id
      LEFT JOIN item_units iu ON iu.item_id = i.id AND iu.is_base_unit = 1
      LEFT JOIN transaction_items ti ON ti.item_id = i.id
      LEFT JOIN transactions t ON t.id = ti.transaction_id AND t.is_deleted = 0
      WHERE ${where.join(' AND ')}
      GROUP BY i.id
      ORDER BY ${_orderBy(sort)}
    ''', args);

    return rows.map(InventoryItem.fromMap).toList();
  }

  String _orderBy(InventorySort sort) {
    switch (sort) {
      case InventorySort.alphabetical:
        return 'i.name COLLATE NOCASE ASC';
      case InventorySort.lowStockFirst:
        return '''
          CASE
            WHEN i.current_stock <= 0 THEN 0
            WHEN i.min_stock_level > 0 AND i.current_stock <= i.min_stock_level THEN 1
            ELSE 2
          END ASC,
          i.name COLLATE NOCASE ASC''';
      case InventorySort.mostActive:
        // NULLs (never-transacted items) sort last.
        return 'last_activity_date IS NULL ASC, last_activity_date DESC, '
            'i.name COLLATE NOCASE ASC';
    }
  }

  /// Real stock-movement rows for an item between [from] and [to] (inclusive,
  /// ISO date strings), newest first. Does NOT include the synthetic opening
  /// stock row — the provider appends that.
  Future<List<JourneyEntry>> getJourney(
    int itemId, {
    required String from,
    required String to,
  }) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT t.transaction_type, t.transaction_number, t.transaction_date,
        p.name AS party_name,
        ti.quantity, ti.unit_name, ti.unit_price, ti.conversion_factor
      FROM transaction_items ti
      JOIN transactions t ON t.id = ti.transaction_id
      LEFT JOIN parties p ON p.id = t.party_id
      WHERE ti.item_id = ?
        AND t.is_deleted = 0
        AND t.transaction_date BETWEEN ? AND ?
        AND t.transaction_type IN ($_stockTypes)
      ORDER BY t.transaction_date DESC, t.created_at DESC
    ''', [itemId, from, to]);

    return rows.map(JourneyEntry.fromMap).toList();
  }

  /// Header summary for the journey screen (current stock, value, opening stock).
  Future<InventoryHeader?> getHeader(int itemId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT i.name, i.current_stock, i.min_stock_level, i.opening_stock,
        i.created_at, i.purchase_price AS item_purchase_price,
        iu.unit_name AS base_unit, iu.purchase_price AS purchase_price
      FROM items i
      LEFT JOIN item_units iu ON iu.item_id = i.id AND iu.is_base_unit = 1
      WHERE i.id = ?
    ''', [itemId]);
    return rows.isEmpty ? null : InventoryHeader.fromMap(rows.first);
  }
}
