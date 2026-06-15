import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Transaction, ConflictAlgorithm;

import '../../../core/database/database_helper.dart';
import '../models/payment.dart';
import '../models/transaction.dart' as model;
import '../models/transaction_item.dart';

/// Data access for transactions (sale / purchase / estimate / expense /
/// other_income) plus their line items and the initial payment.
///
/// Writes go through a single DB transaction so the master row, its lines, and
/// the opening payment are atomic. Stock movement and balance/status updates are
/// handled by DB triggers (see DatabaseHelper), so this layer never touches
/// items.current_stock or transactions.paid_amount after the trigger fires.
class TransactionRepository {
  static const _businessId = 1;

  // ─────────────────────────────────────────
  // LIST QUERIES
  // ─────────────────────────────────────────

  /// Transactions of the given [types], newest first. [paymentStatus] filters to
  /// paid/unpaid/partial; [search] matches number or party name.
  Future<List<model.Transaction>> list(
    List<String> types, {
    String? paymentStatus,
    String? search,
    DateTime? from,
    DateTime? to,
  }) async {
    final db = await DatabaseHelper.database;
    final typePlaceholders = List.filled(types.length, '?').join(',');

    final where = <String>[
      't.business_id = ?',
      't.is_deleted = 0',
      't.transaction_type IN ($typePlaceholders)',
    ];
    final args = <Object?>[_businessId, ...types];

    if (paymentStatus != null && paymentStatus != 'all') {
      where.add('t.payment_status = ?');
      args.add(paymentStatus);
    }
    if (from != null) {
      where.add('t.transaction_date >= ?');
      args.add(from.toIso8601String());
    }
    if (to != null) {
      where.add('t.transaction_date <= ?');
      args.add(to.toIso8601String());
    }
    if (search != null && search.trim().isNotEmpty) {
      where.add('(t.transaction_number LIKE ? OR p.name LIKE ?)');
      final like = '%${search.trim()}%';
      args..add(like)..add(like);
    }

    final rows = await db.rawQuery('''
      SELECT t.*, p.name AS party_name, c.name AS category_name,
        a.name AS account_name
      FROM transactions t
      LEFT JOIN parties p ON p.id = t.party_id
      LEFT JOIN expense_categories c ON c.id = t.category_id
      LEFT JOIN accounts a ON a.id = t.account_id
      WHERE ${where.join(' AND ')}
      ORDER BY t.transaction_date DESC, t.id DESC
    ''', args);

    return rows.map(model.Transaction.fromMap).toList();
  }

  /// Count of (non-deleted, non-cancelled) transactions of a single [type].
  /// Used to derive the next sequential Credit Note number ("CN N").
  Future<int> countByType(String type) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT COUNT(*) AS c FROM transactions
      WHERE business_id = ? AND is_deleted = 0 AND status != 'cancelled'
        AND transaction_type = ?
    ''', [_businessId, type]);
    return (rows.first['c'] as int?) ?? 0;
  }

  /// Header-level summary (count + totals) for a set of types, honouring the
  /// same status filter as [list]. Used by the list-screen summary bar.
  Future<Map<String, double>> summary(List<String> types) async {
    final db = await DatabaseHelper.database;
    final ph = List.filled(types.length, '?').join(',');
    final rows = await db.rawQuery('''
      SELECT
        COALESCE(SUM(total_amount), 0)   AS total,
        COALESCE(SUM(paid_amount), 0)    AS paid,
        COALESCE(SUM(balance_amount), 0) AS outstanding
      FROM transactions
      WHERE business_id = ? AND is_deleted = 0 AND status != 'cancelled'
        AND transaction_type IN ($ph)
    ''', [_businessId, ...types]);
    final r = rows.first;
    return {
      'total': (r['total'] as num?)?.toDouble() ?? 0,
      'paid': (r['paid'] as num?)?.toDouble() ?? 0,
      'outstanding': (r['outstanding'] as num?)?.toDouble() ?? 0,
    };
  }

  // ─────────────────────────────────────────
  // DASHBOARD OUTSTANDING TOTALS
  // ─────────────────────────────────────────

  /// Total still owed *to* the business: Σ(total − paid) over active, non-deleted
  /// sales that still carry a balance. Returns 0 when there's nothing outstanding.
  Future<double> getOutstandingReceivables() =>
      _outstandingForType(model.TxnTypes.sale);

  /// Total the business still owes *out*: Σ(total − paid) over active, non-deleted
  /// purchases that still carry a balance. Returns 0 when nothing is outstanding.
  Future<double> getOutstandingPayables() =>
      _outstandingForType(model.TxnTypes.purchase);

  /// Σ(total_amount − paid_amount) for one [type], counting only rows with a
  /// remaining balance. Cancelled and soft-deleted rows are excluded. A null SUM
  /// (no matching rows) collapses to 0 so the dashboard can show ₹0.
  Future<double> _outstandingForType(String type) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT COALESCE(SUM(total_amount - paid_amount), 0) AS outstanding
      FROM transactions
      WHERE business_id = ?
        AND transaction_type = ?
        AND is_deleted = 0
        AND status != 'cancelled'
        AND balance_amount > 0
    ''', [_businessId, type]);
    return (rows.first['outstanding'] as num?)?.toDouble() ?? 0;
  }

  // ─────────────────────────────────────────
  // DETAIL
  // ─────────────────────────────────────────

  Future<model.Transaction?> getById(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT t.*, p.name AS party_name, c.name AS category_name,
        a.name AS account_name
      FROM transactions t
      LEFT JOIN parties p ON p.id = t.party_id
      LEFT JOIN expense_categories c ON c.id = t.category_id
      LEFT JOIN accounts a ON a.id = t.account_id
      WHERE t.id = ?
    ''', [id]);
    return rows.isEmpty ? null : model.Transaction.fromMap(rows.first);
  }

  Future<List<TransactionItem>> getItems(int transactionId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query('transaction_items',
        where: 'transaction_id = ?',
        whereArgs: [transactionId],
        orderBy: 'sort_order ASC, id ASC');
    return rows.map(TransactionItem.fromMap).toList();
  }

  Future<List<Payment>> getPayments(int transactionId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT py.*, pm.name AS mode_name, a.name AS account_name
      FROM payments py
      LEFT JOIN payment_modes pm ON pm.id = py.payment_mode_id
      LEFT JOIN accounts a ON a.id = py.account_id
      WHERE py.transaction_id = ?
      ORDER BY py.payment_date ASC, py.id ASC
    ''', [transactionId]);
    return rows.map(Payment.fromMap).toList();
  }

  // ─────────────────────────────────────────
  // SAVE (create)
  // ─────────────────────────────────────────

  /// Creates a transaction with its line items and (optionally) an opening
  /// payment, atomically. Returns the new transaction id.
  ///
  /// [initialPayment] is inserted only when its amount > 0; the payment trigger
  /// then derives paid_amount / balance_amount / payment_status and moves the
  /// account balance. For credit (unpaid) saves, pass null.
  ///
  /// [counterType] ('sale' / 'purchase') advances that type's per-prefix
  /// counter when supplied, so numbering stays sequential. Estimates / challans
  /// / returns / orders derive their numbers from a count and pass null.
  Future<int> create(
    model.Transaction txn,
    List<TransactionItem> items, {
    Payment? initialPayment,
    String? counterType,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();

    return db.transaction((sql) async {
      final id = await sql.insert('transactions', {
        ...txn.toMap(),
        // Start unpaid; the payment trigger will adjust these if a payment is
        // inserted below. This keeps the trigger's accumulation correct.
        'paid_amount': 0,
        'balance_amount': txn.totalAmount,
        'payment_status': 'unpaid',
        'created_at': now,
        'updated_at': now,
      });

      for (var i = 0; i < items.length; i++) {
        await sql.insert('transaction_items', {
          ...items[i].toMap(),
          'transaction_id': id,
          'sort_order': items[i].sortOrder == 0 ? i : items[i].sortOrder,
        });
      }

      if (initialPayment != null && initialPayment.amount > 0) {
        await sql.insert('payments', {
          ...initialPayment.toMap(),
          'transaction_id': id,
        });
      }

      return id;
    }).then((id) async {
      // Advance the per-prefix counter (counter_<type>_<PREFIX>) AFTER the
      // insert transaction commits — consumeDocNumber writes through the shared
      // connection, so doing it inside the open transaction could deadlock. The
      // txn already carries the peeked number, so this only moves the sequence.
      if (counterType != null) {
        await DatabaseHelper.consumeDocNumber(counterType);
      }
      return id;
    });
  }

  // ─────────────────────────────────────────
  // EDIT (only allowed when no payments recorded)
  // ─────────────────────────────────────────

  /// True when the transaction can still be edited (no payments recorded yet).
  Future<bool> isEditable(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM payments WHERE transaction_id = ?', [id]);
    return ((rows.first['c'] as int?) ?? 0) == 0;
  }

  /// Replaces a transaction's header + line items. Only valid before any payment
  /// exists. Deleting the old line rows fires no stock trigger (triggers are
  /// AFTER INSERT only), so we manually reverse the old lines' stock first, then
  /// re-insert the new lines (which re-applies stock via triggers).
  Future<void> updateTransaction(
    model.Transaction txn,
    List<TransactionItem> items,
  ) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    final id = txn.id!;

    await db.transaction((sql) async {
      // Reverse stock effect of the existing lines before replacing them.
      await _reverseStock(sql, id);
      await sql.delete('transaction_items', where: 'transaction_id = ?', whereArgs: [id]);

      await sql.update(
        'transactions',
        {
          ...txn.toMap(),
          'paid_amount': 0,
          'balance_amount': txn.totalAmount,
          'payment_status': 'unpaid',
          'updated_at': now,
        },
        where: 'id = ?',
        whereArgs: [id],
      );

      for (var i = 0; i < items.length; i++) {
        await sql.insert('transaction_items', {
          ...items[i].toMap(),
          'transaction_id': id,
          'sort_order': items[i].sortOrder == 0 ? i : items[i].sortOrder,
        });
      }
    });
  }

  // ─────────────────────────────────────────
  // RECORD PAYMENT (from detail screen)
  // ─────────────────────────────────────────

  /// Inserts an additional payment. Triggers update the transaction balance /
  /// status and the account balance.
  Future<void> recordPayment(Payment payment) async {
    final db = await DatabaseHelper.database;
    await db.insert('payments', payment.toMap());
  }

  // ─────────────────────────────────────────
  // CANCEL / DELETE
  // ─────────────────────────────────────────

  /// Cancels a transaction: reverses its stock movement, marks it cancelled, and
  /// removes its payments (refunding the account balance) so balances stay
  /// correct. The row is kept (status = 'cancelled') for the audit trail.
  Future<void> cancel(int id) async {
    final db = await DatabaseHelper.database;
    await db.transaction((sql) async {
      await _reverseStock(sql, id);
      await _reversePayments(sql, id);
      await sql.update(
        'transactions',
        {
          'status': 'cancelled',
          'paid_amount': 0,
          'balance_amount': 0,
          'payment_status': 'unpaid',
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  /// Soft-deletes a transaction (is_deleted = 1) after reversing its stock and
  /// payments, so it disappears from lists and balances without losing history.
  Future<void> softDelete(int id) async {
    final db = await DatabaseHelper.database;
    await db.transaction((sql) async {
      await _reverseStock(sql, id);
      await _reversePayments(sql, id);
      await sql.update(
        'transactions',
        {
          'is_deleted': 1,
          'deleted_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [id],
      );
    });
  }

  // ─────────────────────────────────────────
  // ESTIMATE → INVOICE
  // ─────────────────────────────────────────

  /// Converts an estimate into a new sale, copying its line items. Marks the
  /// estimate `status = 'converted'` and links the new sale back to it. Returns
  /// the new sale id. The caller supplies the freshly generated invoice number.
  Future<int> convertEstimateToSale(int estimateId, String invoiceNumber) async {
    final db = await DatabaseHelper.database;
    final estimate = await getById(estimateId);
    if (estimate == null) throw StateError('Estimate not found');
    final lines = await getItems(estimateId);
    final now = DateTime.now().toIso8601String();

    return db.transaction((sql) async {
      final saleId = await sql.insert('transactions', {
        ...estimate.toMap(),
        'transaction_type': 'sale',
        'transaction_number': invoiceNumber,
        'status': 'active',
        'paid_amount': 0,
        'balance_amount': estimate.totalAmount,
        'payment_status': 'unpaid',
        'linked_transaction_id': estimateId,
        'created_at': now,
        'updated_at': now,
      });
      // Drop the id-bearing fields so each line inserts fresh against the sale.
      for (final l in lines) {
        final map = l.toMap()..remove('id');
        await sql.insert('transaction_items', {...map, 'transaction_id': saleId});
      }
      await sql.update(
        'transactions',
        {'status': 'converted', 'updated_at': now},
        where: 'id = ?',
        whereArgs: [estimateId],
      );
      return saleId;
    }).then((saleId) async {
      // Advance the sale per-prefix counter after commit (see create()).
      await DatabaseHelper.consumeDocNumber('sale');
      return saleId;
    });
  }

  // ─────────────────────────────────────────
  // DELIVERY CHALLAN → INVOICE
  // ─────────────────────────────────────────

  /// Converts a delivery challan into a new sale, copying its line items. Marks
  /// the challan `status = 'converted'` and links the new sale back to it.
  /// Returns the new sale id. The caller supplies the generated invoice number.
  Future<int> convertChallanToSale(int challanId, String invoiceNumber) async {
    final db = await DatabaseHelper.database;
    final challan = await getById(challanId);
    if (challan == null) throw StateError('Delivery challan not found');
    final lines = await getItems(challanId);
    final now = DateTime.now().toIso8601String();

    return db.transaction((sql) async {
      final saleId = await sql.insert('transactions', {
        ...challan.toMap(),
        'transaction_type': 'sale',
        'transaction_number': invoiceNumber,
        'status': 'active',
        'paid_amount': 0,
        'balance_amount': challan.totalAmount,
        'payment_status': 'unpaid',
        'linked_transaction_id': challanId,
        'created_at': now,
        'updated_at': now,
      });
      // Drop the id-bearing fields so each line inserts fresh against the sale.
      for (final l in lines) {
        final map = l.toMap()..remove('id');
        await sql.insert('transaction_items', {...map, 'transaction_id': saleId});
      }
      await sql.update(
        'transactions',
        {'status': 'converted', 'updated_at': now},
        where: 'id = ?',
        whereArgs: [challanId],
      );
      return saleId;
    }).then((saleId) async {
      // Advance the sale per-prefix counter after commit (see create()).
      await DatabaseHelper.consumeDocNumber('sale');
      return saleId;
    });
  }

  // ─────────────────────────────────────────
  // INTERNAL — stock & payment reversal
  // ─────────────────────────────────────────

  /// Reverses the stock movement caused by a transaction's line items. Sales /
  /// purchase-returns had stock decreased, so we add it back; purchases /
  /// sale-returns had it increased, so we subtract. No-op for non-stock types.
  Future<void> _reverseStock(Transaction sql, int transactionId) async {
    final header = await sql.query('transactions',
        columns: ['transaction_type'], where: 'id = ?', whereArgs: [transactionId]);
    if (header.isEmpty) return;
    final type = header.first['transaction_type'] as String?;

    final int sign;
    switch (type) {
      case 'sale':
      case 'purchase_return':
        sign = 1; // stock was reduced → add back
        break;
      case 'purchase':
      case 'sale_return':
        sign = -1; // stock was added → remove
        break;
      default:
        return; // estimate / expense / income — no stock effect
    }

    final lines = await sql.query('transaction_items',
        columns: ['item_id', 'quantity', 'conversion_factor'],
        where: 'transaction_id = ? AND item_id IS NOT NULL',
        whereArgs: [transactionId]);

    for (final l in lines) {
      final itemId = l['item_id'] as int;
      final qty = (l['quantity'] as num).toDouble();
      final cf = (l['conversion_factor'] as num?)?.toDouble() ?? 1;
      await sql.rawUpdate(
        'UPDATE items SET current_stock = current_stock + ?, '
        "updated_at = datetime('now') WHERE id = ?",
        [sign * qty * cf, itemId],
      );
    }
  }

  /// Refunds account balances for a transaction's payments, then deletes them.
  /// The balance-trigger only runs on INSERT, so we undo its effect by hand.
  Future<void> _reversePayments(Transaction sql, int transactionId) async {
    final header = await sql.query('transactions',
        columns: ['transaction_type'], where: 'id = ?', whereArgs: [transactionId]);
    if (header.isEmpty) return;
    final type = header.first['transaction_type'] as String?;

    // Which direction did the original payment move the account?
    final int sign;
    if (type == 'sale' || type == 'payment_in' || type == 'other_income') {
      sign = -1; // money had come IN → take it back out
    } else if (type == 'purchase' || type == 'payment_out' || type == 'expense') {
      sign = 1; // money had gone OUT → put it back
    } else {
      sign = 0;
    }

    if (sign != 0) {
      final pays = await sql.query('payments',
          columns: ['account_id', 'amount'],
          where: 'transaction_id = ? AND account_id IS NOT NULL',
          whereArgs: [transactionId]);
      for (final p in pays) {
        await sql.rawUpdate(
          'UPDATE accounts SET current_balance = current_balance + ?, '
          "updated_at = datetime('now') WHERE id = ?",
          [sign * (p['amount'] as num).toDouble(), p['account_id']],
        );
      }
    }

    await sql.delete('payments', where: 'transaction_id = ?', whereArgs: [transactionId]);
  }

  // ─────────────────────────────────────────
  // EXPENSE / INCOME (no line items)
  // ─────────────────────────────────────────

  /// Creates an expense or other_income transaction with an immediate full
  /// payment (these are never on credit). Returns the new id.
  Future<int> createCashTransaction(
    model.Transaction txn, {
    required Payment payment,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    return db.transaction((sql) async {
      final id = await sql.insert('transactions', {
        ...txn.toMap(),
        'paid_amount': 0,
        'balance_amount': txn.totalAmount,
        'payment_status': 'unpaid',
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      await sql.insert('payments', {...payment.toMap(), 'transaction_id': id});
      return id;
    });
  }
}
