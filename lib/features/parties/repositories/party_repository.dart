import '../../../core/database/database_helper.dart';
import '../models/party.dart';

/// Data access for parties. All writes are soft (is_active) per Phase 2 rules.
class PartyRepository {
  static const _businessId = 1;

  /// Active parties with aggregated outstanding balances, name-sorted.
  /// [type] filters to 'customer' / 'supplier' (a 'both' party matches either);
  /// pass null/'all' for everyone. [search] matches name or phone.
  Future<List<Party>> getParties({String? type, String? search}) async {
    final db = await DatabaseHelper.database;

    final where = <String>['p.business_id = ?', 'p.is_active = 1'];
    final args = <Object?>[_businessId];

    if (type == 'customer') {
      where.add("p.party_type IN ('customer','both')");
    } else if (type == 'supplier') {
      where.add("p.party_type IN ('supplier','both')");
    }

    if (search != null && search.trim().isNotEmpty) {
      where.add('(p.name LIKE ? OR p.phone LIKE ?)');
      final like = '%${search.trim()}%';
      args..add(like)..add(like);
    }

    final rows = await db.rawQuery('''
      SELECT p.*,
        COALESCE(SUM(CASE WHEN t.transaction_type = 'sale'
          THEN t.balance_amount ELSE 0 END), 0) AS to_collect,
        COALESCE(SUM(CASE WHEN t.transaction_type = 'purchase'
          THEN t.balance_amount ELSE 0 END), 0) AS to_pay
      FROM parties p
      LEFT JOIN transactions t ON t.party_id = p.id AND t.is_deleted = 0
      WHERE ${where.join(' AND ')}
      GROUP BY p.id
      ORDER BY p.name COLLATE NOCASE ASC
    ''', args);

    return rows.map(Party.fromMap).toList();
  }

  Future<Party?> getById(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT p.*,
        COALESCE(SUM(CASE WHEN t.transaction_type = 'sale'
          THEN t.balance_amount ELSE 0 END), 0) AS to_collect,
        COALESCE(SUM(CASE WHEN t.transaction_type = 'purchase'
          THEN t.balance_amount ELSE 0 END), 0) AS to_pay
      FROM parties p
      LEFT JOIN transactions t ON t.party_id = p.id AND t.is_deleted = 0
      WHERE p.id = ?
      GROUP BY p.id
    ''', [id]);
    return rows.isEmpty ? null : Party.fromMap(rows.first);
  }

  Future<int> insert(Party party) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    return db.insert('parties', {
      ...party.toMap(),
      'created_at': now,
      'updated_at': now,
    });
  }

  Future<void> update(Party party) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'parties',
      {...party.toMap(), 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [party.id],
    );
  }

  /// Soft delete — never removes the row.
  Future<void> softDelete(int id) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'parties',
      {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<int> transactionCount(int partyId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM transactions WHERE party_id = ? AND is_deleted = 0',
      [partyId],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  /// All non-deleted transactions for this party, newest first.
  Future<List<Map<String, dynamic>>> transactions(int partyId) async {
    final db = await DatabaseHelper.database;
    return db.rawQuery('''
      SELECT id, transaction_type, transaction_number, transaction_date,
        total_amount, balance_amount
      FROM transactions
      WHERE party_id = ? AND is_deleted = 0
      ORDER BY transaction_date DESC, id DESC
    ''', [partyId]);
  }
}
