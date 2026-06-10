import '../../../core/database/database_helper.dart';
import '../models/unit.dart';

/// Data access for units of measurement. Soft delete only.
class UnitRepository {
  static const _businessId = 1;

  Future<List<Unit>> getUnits() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'units',
      where: 'business_id = ? AND is_active = 1',
      whereArgs: [_businessId],
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return rows.map(Unit.fromMap).toList();
  }

  Future<int> insert(String name, String shortName) async {
    final db = await DatabaseHelper.database;
    return db.insert('units', {
      'business_id': _businessId,
      'name': name.trim(),
      'short_name': shortName.trim(),
      'is_active': 1,
    });
  }

  Future<void> update(int id, String name, String shortName) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'units',
      {'name': name.trim(), 'short_name': shortName.trim()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Count of active items using this unit (used to block deletion).
  Future<int> itemCount(int unitId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM items WHERE unit_id = ? AND is_active = 1',
      [unitId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> softDelete(int id) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'units',
      {'is_active': 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
