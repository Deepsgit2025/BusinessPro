import '../../../core/database/database_helper.dart';
import '../models/account.dart';

/// Data access for cash / bank / wallet accounts and their statements.
class AccountRepository {
  static const _businessId = 1;

  Future<List<Account>> getAccounts() async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'accounts',
      where: 'business_id = ? AND is_active = 1',
      whereArgs: [_businessId],
      orderBy: 'is_default DESC, name COLLATE NOCASE ASC',
    );
    return rows.map(Account.fromMap).toList();
  }

  Future<Account?> getById(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('accounts', where: 'id = ?', whereArgs: [id], limit: 1);
    return rows.isEmpty ? null : Account.fromMap(rows.first);
  }

  /// The id of an account linked from the business profile (see
  /// [upsertLinkedAccount]) — e.g. `linked_upi_account_id` — or null if none is
  /// linked or it was since deleted. Used to default the deposit / pay-from
  /// account when paying by UPI.
  Future<int?> linkedAccountId(String settingKey) async {
    final id = int.tryParse(await DatabaseHelper.getSettingStr(settingKey));
    if (id == null) return null;
    final db = await DatabaseHelper.database;
    final rows = await db.query('accounts',
        columns: ['id'],
        where: 'id = ? AND is_active = 1',
        whereArgs: [id],
        limit: 1);
    return rows.isEmpty ? null : id;
  }

  /// Sum of current balances across all active accounts.
  Future<double> totalBalance() async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
      'SELECT COALESCE(SUM(current_balance), 0) AS t FROM accounts '
      'WHERE business_id = ? AND is_active = 1',
      [_businessId],
    );
    return (rows.first['t'] as num?)?.toDouble() ?? 0;
  }

  /// True when an active `cash`-type account already exists (optionally
  /// ignoring [excludeId], for the account being edited). Used to enforce the
  /// "exactly one cash account" rule — banks/wallets can be many.
  Future<bool> hasCashAccount({int? excludeId}) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'accounts',
      columns: ['id'],
      where: "business_id = ? AND is_active = 1 AND account_type = 'cash'"
          '${excludeId == null ? '' : ' AND id != ?'}',
      whereArgs: [_businessId, ?excludeId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  /// Inserts an account, seeding current_balance from opening_balance. When
  /// [account.isDefault] is set, clears the flag on all other accounts first.
  /// Rejects a second cash account (only one is allowed).
  Future<int> insert(Account account) async {
    if (account.accountType == 'cash' && await hasCashAccount()) {
      throw StateError(
          'Only one cash account is allowed. Add a bank or wallet instead.');
    }
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    return db.transaction((txn) async {
      if (account.isDefault) {
        await txn.update('accounts', {'is_default': 0},
            where: 'business_id = ?', whereArgs: [_businessId]);
      }
      return txn.insert('accounts', {
        ...account.toMap(),
        'current_balance': account.openingBalance,
        'created_at': now,
        'updated_at': now,
      });
    });
  }

  /// Updates an account. current_balance is left untouched (payment triggers and
  /// transfers drive it), but a change to opening_balance is applied as a delta
  /// to current_balance so the running ledger stays consistent.
  Future<void> update(Account account) async {
    if (account.accountType == 'cash' &&
        await hasCashAccount(excludeId: account.id)) {
      throw StateError(
          'Only one cash account is allowed. Add a bank or wallet instead.');
    }
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    final existing = await getById(account.id!);
    final openingDelta =
        existing == null ? 0.0 : account.openingBalance - existing.openingBalance;

    await db.transaction((txn) async {
      if (account.isDefault) {
        await txn.update('accounts', {'is_default': 0},
            where: 'business_id = ? AND id != ?',
            whereArgs: [_businessId, account.id]);
      }
      await txn.update(
        'accounts',
        {
          ...account.toMap(),
          if (openingDelta != 0)
            'current_balance': (existing!.currentBalance + openingDelta),
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [account.id],
      );
    });
  }

  Future<void> softDelete(int id) async {
    final db = await DatabaseHelper.database;
    await db.update('accounts', {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?', whereArgs: [id]);
  }

  /// Creates or refreshes a Cash & Bank account that mirrors a block on the
  /// business profile (the bank account, or the UPI handle) so the user doesn't
  /// enter the same details twice. Idempotent: the account id is remembered in
  /// the [settingKey] setting, so a later profile save updates the SAME row
  /// instead of making duplicates. The account stays fully editable in Cash &
  /// Bank — we only (re)fill the identity fields here, never the name on update
  /// (so a user rename sticks) nor the balance / default flag. Returns the
  /// account id, or null when there's nothing to link (blank [name]).
  Future<int?> upsertLinkedAccount({
    required String settingKey,
    required String name,
    required String accountType, // 'bank' | 'wallet'
    String? bankName,
    String? accountNumber,
    String? ifscCode,
  }) async {
    if (name.trim().isEmpty) return null;
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();

    final linkedId =
        int.tryParse(await DatabaseHelper.getSettingStr(settingKey));
    if (linkedId != null) {
      final existing = await db.query('accounts',
          where: 'id = ? AND is_active = 1', whereArgs: [linkedId], limit: 1);
      if (existing.isNotEmpty) {
        await db.update(
          'accounts',
          {
            'account_type': accountType,
            'bank_name': bankName,
            'account_number': accountNumber,
            'ifsc_code': ifscCode,
            'updated_at': now,
          },
          where: 'id = ?',
          whereArgs: [linkedId],
        );
        return linkedId;
      }
    }

    final id = await insert(Account(
      name: name.trim(),
      accountType: accountType,
      bankName: bankName,
      accountNumber: accountNumber,
      ifscCode: ifscCode,
    ));
    await DatabaseHelper.setSetting(settingKey, id.toString());
    return id;
  }

  /// Running-balance ledger for an account. Returns rows in chronological order
  /// with money_in / money_out and a computed running balance starting from the
  /// account's opening balance.
  Future<List<Map<String, dynamic>>> statement(
    int accountId, {
    String? fromDate,
    String? toDate,
  }) async {
    final db = await DatabaseHelper.database;
    final account = await getById(accountId);
    final opening = account?.openingBalance ?? 0;

    final where = <String>['py.account_id = ?', 't.is_deleted = 0'];
    final args = <Object?>[accountId];
    if (fromDate != null) {
      where.add('t.transaction_date >= ?');
      args.add(fromDate);
    }
    if (toDate != null) {
      where.add('t.transaction_date <= ?');
      args.add(toDate);
    }

    final rows = await db.rawQuery('''
      SELECT
        t.id              AS transaction_id,
        t.transaction_date,
        t.transaction_number,
        t.transaction_type,
        p.name            AS party_name,
        py.amount,
        py.notes          AS payment_notes,
        CASE WHEN t.transaction_type IN
          ('sale','other_income','payment_in') THEN py.amount ELSE 0 END AS money_in,
        CASE WHEN t.transaction_type IN
          ('purchase','expense','payment_out') THEN py.amount ELSE 0 END AS money_out
      FROM payments py
      JOIN transactions t ON t.id = py.transaction_id
      LEFT JOIN parties p ON p.id = t.party_id
      WHERE ${where.join(' AND ')}
      ORDER BY t.transaction_date ASC, py.created_at ASC, py.id ASC
    ''', args);

    // Fold a running balance through the rows.
    double running = opening;
    final ledger = <Map<String, dynamic>>[];
    for (final r in rows) {
      running += (r['money_in'] as num).toDouble() - (r['money_out'] as num).toDouble();
      ledger.add({...r, 'running_balance': running});
    }
    return ledger;
  }

  /// Transfers money between two accounts. Records a paired payment_out (source)
  /// and payment_in (destination) under two internal transfer transactions so
  /// the account-balance triggers move the money. Returns nothing on success.
  Future<void> transfer({
    required int fromAccountId,
    required int toAccountId,
    required double amount,
    required String date,
    String? notes,
    int? cashModeId,
  }) async {
    if (fromAccountId == toAccountId) {
      throw ArgumentError('Source and destination accounts must differ');
    }
    final db = await DatabaseHelper.database;
    final number = 'TRF-${DateTime.now().millisecondsSinceEpoch}';

    await db.transaction((txn) async {
      // Out leg — payment_out drains the source account.
      final outId = await txn.insert('transactions', {
        'business_id': _businessId,
        'account_id': fromAccountId,
        'transaction_type': 'payment_out',
        'transaction_number': '$number-O',
        'transaction_date': date,
        'total_amount': amount,
        'paid_amount': 0,
        'balance_amount': 0,
        'payment_status': 'paid',
        'status': 'active',
        'notes': notes ?? 'Transfer out',
      });
      await txn.insert('payments', {
        'transaction_id': outId,
        'account_id': fromAccountId,
        'payment_mode_id': cashModeId,
        'amount': amount,
        'payment_date': date,
        'notes': 'Account transfer',
      });

      // In leg — payment_in fills the destination account.
      final inId = await txn.insert('transactions', {
        'business_id': _businessId,
        'account_id': toAccountId,
        'transaction_type': 'payment_in',
        'transaction_number': '$number-I',
        'transaction_date': date,
        'total_amount': amount,
        'paid_amount': 0,
        'balance_amount': 0,
        'payment_status': 'paid',
        'status': 'active',
        'notes': notes ?? 'Transfer in',
        'linked_transaction_id': outId,
      });
      await txn.insert('payments', {
        'transaction_id': inId,
        'account_id': toAccountId,
        'payment_mode_id': cashModeId,
        'amount': amount,
        'payment_date': date,
        'notes': 'Account transfer',
      });
    });
  }
}
