import '../../../core/database/database_helper.dart';
import '../models/expense_category.dart';
import '../models/payment_mode.dart';

/// Data access for the small master tables shared by transaction screens:
/// payment modes and expense/income categories.
class TxnMetaRepository {
  static const _businessId = 1;

  Future<List<PaymentMode>> paymentModes() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('payment_modes',
        where: 'business_id = ? AND is_active = 1',
        whereArgs: [_businessId],
        orderBy: 'id ASC');
    return rows.map(PaymentMode.fromMap).toList();
  }

  /// Categories for expense screens ('expense' + 'both') or income screens
  /// ('income' + 'both'), per [categoryFor].
  Future<List<ExpenseCategory>> categories(String categoryFor) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('expense_categories',
        where: "business_id = ? AND is_active = 1 AND category_for IN (?, 'both')",
        whereArgs: [_businessId, categoryFor],
        orderBy: 'name COLLATE NOCASE ASC');
    return rows.map(ExpenseCategory.fromMap).toList();
  }

  Future<int> addCategory(String name, String categoryFor) async {
    final db = await DatabaseHelper.database;
    return db.insert('expense_categories', {
      'business_id': _businessId,
      'name': name,
      'category_for': categoryFor,
      'is_active': 1,
    });
  }

  /// The id of the Cash-type payment mode, used as a sensible default.
  Future<int?> defaultPaymentModeId() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('payment_modes',
        columns: ['id'],
        where: "business_id = ? AND is_active = 1 AND type = 'cash'",
        whereArgs: [_businessId],
        limit: 1);
    return rows.isEmpty ? null : rows.first['id'] as int;
  }
}
