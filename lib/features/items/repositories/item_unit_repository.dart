import '../../../core/database/database_helper.dart';
import '../models/item_unit.dart';

/// Data access for an item's selling-unit tiers (`item_units`).
class ItemUnitRepository {
  /// All active unit tiers for an item, smallest packing first.
  Future<List<ItemUnit>> getItemUnits(int itemId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'item_units',
      where: 'item_id = ? AND is_active = 1',
      whereArgs: [itemId],
      orderBy: 'sort_order ASC, conversion_factor ASC, id ASC',
    );
    return rows.map(ItemUnit.fromMap).toList();
  }

  Future<int> addItemUnit(ItemUnit unit) async {
    final db = await DatabaseHelper.database;
    return db.insert('item_units', unit.toMap());
  }

  Future<void> updateItemUnit(ItemUnit unit) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'item_units',
      unit.toMap(),
      where: 'id = ?',
      whereArgs: [unit.id],
    );
  }

  /// Deletes a tier, but only if it has never been used on a transaction line.
  /// Returns false (and deletes nothing) when the tier is referenced.
  Future<bool> deleteItemUnit(int id) async {
    final db = await DatabaseHelper.database;
    final used = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM transaction_items WHERE item_unit_id = ?',
      [id],
    );
    if (((used.first['c'] as int?) ?? 0) > 0) return false;
    await db.delete('item_units', where: 'id = ?', whereArgs: [id]);
    return true;
  }

  Future<ItemUnit?> getDefaultSaleUnit(int itemId) =>
      _first(itemId, 'is_default_sale = 1');

  Future<ItemUnit?> getDefaultPurchaseUnit(int itemId) =>
      _first(itemId, 'is_default_purchase = 1');

  Future<ItemUnit?> getBaseUnit(int itemId) =>
      _first(itemId, 'is_base_unit = 1');

  Future<ItemUnit?> _first(int itemId, String extra) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'item_units',
      where: 'item_id = ? AND is_active = 1 AND $extra',
      whereArgs: [itemId],
      limit: 1,
    );
    return rows.isEmpty ? null : ItemUnit.fromMap(rows.first);
  }

  /// Replaces the full tier set for an item in one transaction. Tiers that have
  /// transaction history are kept (soft-deactivated if dropped) so historical
  /// line items still resolve; brand-new tiers are inserted, surviving ones
  /// updated. Used by the item save flow.
  Future<void> replaceItemUnits(int itemId, List<ItemUnit> tiers) async {
    final db = await DatabaseHelper.database;
    await db.transaction((txn) async {
      final existing = await txn.query('item_units',
          columns: ['id'], where: 'item_id = ?', whereArgs: [itemId]);
      final existingIds = existing.map((r) => r['id'] as int).toSet();
      final keptIds = <int>{};

      for (final tier in tiers) {
        final map = {...tier.toMap(), 'item_id': itemId};
        if (tier.id != null && existingIds.contains(tier.id)) {
          await txn.update('item_units', map,
              where: 'id = ?', whereArgs: [tier.id]);
          keptIds.add(tier.id!);
        } else {
          await txn.insert('item_units', map);
        }
      }

      // Drop tiers the user removed. Keep (deactivate) any still referenced by a
      // transaction line so its snapshot stays resolvable; hard-delete the rest.
      for (final id in existingIds.difference(keptIds)) {
        final used = await txn.rawQuery(
          'SELECT COUNT(*) AS c FROM transaction_items WHERE item_unit_id = ?',
          [id],
        );
        if (((used.first['c'] as int?) ?? 0) > 0) {
          await txn.update('item_units', {'is_active': 0},
              where: 'id = ?', whereArgs: [id]);
        } else {
          await txn.delete('item_units', where: 'id = ?', whereArgs: [id]);
        }
      }
    });
  }
}
