import '../../../core/database/database_helper.dart';
import '../models/item_category.dart';

/// Data access for item categories. Soft delete only.
class CategoryRepository {
  static const _businessId = 1;

  /// Active categories with a count of the active items in each, name-sorted.
  Future<List<ItemCategory>> getCategories() async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT c.*,
        (SELECT COUNT(*) FROM items i
          WHERE i.category_id = c.id AND i.is_active = 1) AS item_count
      FROM item_categories c
      WHERE c.business_id = ? AND c.is_active = 1
      ORDER BY c.name COLLATE NOCASE ASC
    ''', [_businessId]);
    return rows.map(ItemCategory.fromMap).toList();
  }

  Future<int> insert(String name) async {
    final db = await DatabaseHelper.database;
    return db.insert('item_categories', {
      'business_id': _businessId,
      'name': name.trim(),
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> rename(int id, String name) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'item_categories',
      {'name': name.trim()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Count of active items assigned to this category (used to block deletion).
  Future<int> itemCount(int categoryId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM items WHERE category_id = ? AND is_active = 1',
      [categoryId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> softDelete(int id) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'item_categories',
      {'is_active': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
