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

  /// Double-entry ledger events for this party, oldest first, for the Statement
  /// tab. Two kinds of rows are unioned:
  ///
  /// 1. **Bills** — each sale / purchase / return at its full total:
  ///    sale & purchase_return ⇒ debit (raises To Collect),
  ///    purchase & sale_return ⇒ credit (raises To Pay).
  /// 2. **Payments** — each real money movement from `payments` (account_id set),
  ///    including the amount paid *at* a sale/purchase's creation AND standalone
  ///    payment_in / payment_out receipts: money in (sale/other_income/
  ///    payment_in) ⇒ credit, money out (purchase/expense/payment_out) ⇒ debit.
  ///    Internal allocation rows (`reference_number 'PAY:<id>'`, account_id NULL)
  ///    are excluded so a receipt isn't double-counted against its own invoice.
  ///
  /// The caller folds a running balance (debit − credit) from the opening
  /// balance. So "purchase 10000, ₹5000 paid at entry, ₹4000 payment-out later"
  /// yields: credit 10000, debit 5000, debit 4000 → net you owe ₹1000.
  Future<List<Map<String, dynamic>>> ledger(int partyId) async {
    final db = await DatabaseHelper.database;
    return db.rawQuery('''
      SELECT date, description, transaction_type, kind, debit, credit FROM (
        SELECT
          t.transaction_date        AS date,
          t.transaction_number      AS description,
          t.transaction_type        AS transaction_type,
          'bill'                    AS kind,
          CASE WHEN t.transaction_type IN ('sale','purchase_return')
            THEN t.total_amount ELSE 0 END AS debit,
          CASE WHEN t.transaction_type IN ('purchase','sale_return')
            THEN t.total_amount ELSE 0 END AS credit
        FROM transactions t
        WHERE t.party_id = ? AND t.is_deleted = 0 AND t.status != 'cancelled'
          AND t.transaction_type IN
            ('sale','purchase','sale_return','purchase_return')

        UNION ALL

        SELECT
          py.payment_date           AS date,
          t.transaction_number      AS description,
          t.transaction_type        AS transaction_type,
          'payment'                 AS kind,
          CASE WHEN t.transaction_type IN ('purchase','expense','payment_out')
            THEN py.amount ELSE 0 END AS debit,
          CASE WHEN t.transaction_type IN ('sale','other_income','payment_in')
            THEN py.amount ELSE 0 END AS credit
        FROM payments py
        JOIN transactions t ON t.id = py.transaction_id
        WHERE t.party_id = ? AND t.is_deleted = 0 AND t.status != 'cancelled'
          AND py.account_id IS NOT NULL
          AND (py.reference_number IS NULL OR py.reference_number NOT LIKE 'PAY:%')
      )
      ORDER BY date ASC, kind ASC, description ASC
    ''', [partyId, partyId]);
  }
}
