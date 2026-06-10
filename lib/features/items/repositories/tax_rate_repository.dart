import '../../../core/database/database_helper.dart';
import '../models/tax_rate.dart';

/// Data access for tax rates. Soft delete only.
class TaxRateRepository {
  static const _businessId = 1;

  Future<List<TaxRate>> getTaxRates() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'tax_rates',
      where: 'business_id = ? AND is_active = 1',
      whereArgs: [_businessId],
      orderBy: 'rate ASC',
    );
    return rows.map(TaxRate.fromMap).toList();
  }

  Future<int> insert(TaxRate rate) async {
    final db = await DatabaseHelper.database;
    return db.insert('tax_rates', rate.toMap());
  }

  Future<void> update(TaxRate rate) async {
    final db = await DatabaseHelper.database;
    await db.update('tax_rates', rate.toMap(), where: 'id = ?', whereArgs: [rate.id]);
  }

  Future<void> softDelete(int id) async {
    final db = await DatabaseHelper.database;
    await db.update('tax_rates', {'is_active': 0}, where: 'id = ?', whereArgs: [id]);
  }
}
