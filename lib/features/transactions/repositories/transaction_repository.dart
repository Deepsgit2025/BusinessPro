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

  /// True when another (non-deleted) transaction already uses [number]. Used to
  /// guard a user-edited document number against collisions. [excludeId] skips
  /// the row being edited so re-saving its own number isn't flagged.
  Future<bool> numberExists(String number, {int? excludeId}) async {
    final db = await DatabaseHelper.database;
    final where = StringBuffer(
        'business_id = ? AND is_deleted = 0 AND transaction_number = ?');
    final args = <Object?>[_businessId, number];
    if (excludeId != null) {
      where.write(' AND id != ?');
      args.add(excludeId);
    }
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM transactions WHERE $where', args);
    return ((rows.first['c'] as int?) ?? 0) > 0;
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
  /// [mintType] — when supplied, the document number is minted ATOMICALLY inside
  /// the insert transaction (`DatabaseHelper.mintDocNumberInTxn`) and stamped on
  /// the row, so the counter advance and the insert commit together. Pass it for
  /// every auto-numbered document (sale, purchase, estimate, challan, returns,
  /// orders, payment_in/out). Pass null only when the number on [txn] is
  /// authoritative as-is — a user-entered override. This closes the duplicate-
  /// number race that the old peek-at-open / consume-after-commit design left
  /// open under "Save & New", rapid saves, and convert-to-sale.
  Future<int> create(
    model.Transaction txn,
    List<TransactionItem> items, {
    Payment? initialPayment,
    String? mintType,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();

    return db.transaction((sql) async {
      final number = mintType != null
          ? await DatabaseHelper.mintDocNumberInTxn(sql, mintType)
          : txn.transactionNumber;
      final id = await sql.insert('transactions', {
        ...txn.toMap(),
        'transaction_number': number,
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
    });
  }

  // ─────────────────────────────────────────
  // EDIT
  // ─────────────────────────────────────────

  /// True when the transaction may be edited. Edits are always allowed: any
  /// recorded payment is reversed (account refunded) and re-applied for the
  /// previously-paid amount against the new total. Cancelled rows are not
  /// editable. Kept as a Future so callers (the UI gate) need not change shape.
  Future<bool> isEditable(int id) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery(
        'SELECT status FROM transactions WHERE id = ?', [id]);
    if (rows.isEmpty) return false;
    return rows.first['status'] != 'cancelled';
  }

  /// Replaces a transaction's header + line items, preserving any amount already
  /// paid. Deleting the old line rows fires no stock trigger (triggers are AFTER
  /// INSERT only), so we manually reverse the old lines' stock first, then
  /// re-insert the new lines (which re-applies stock via triggers).
  ///
  /// Existing payments are reversed (refunding the account) and a single
  /// payment for the previously-paid total — clamped to the new total — is
  /// re-inserted using the original account/mode, so the payment trigger
  /// re-derives paid_amount / balance_amount / payment_status correctly and the
  /// account balance nets out. A paid-in-full invoice whose total drops keeps
  /// only what the new total can absorb; the rest is refunded to the account.
  Future<void> updateTransaction(
    model.Transaction txn,
    List<TransactionItem> items,
  ) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    final id = txn.id!;

    await db.transaction((sql) async {
      // Snapshot the existing payments before reversing them, so the same money
      // (account + mode) can be re-applied against the edited total.
      final priorPayments = await sql.query('payments',
          columns: ['account_id', 'payment_mode_id', 'amount', 'payment_date'],
          where: 'transaction_id = ?',
          whereArgs: [id],
          orderBy: 'payment_date ASC, id ASC');
      final priorPaid = priorPayments.fold<double>(
          0, (s, p) => s + (p['amount'] as num).toDouble());

      // Reverse the old payments (refund account) and the old lines' stock
      // before replacing them.
      await _reversePayments(sql, id);
      await _reverseStock(sql, id);
      await sql.delete('transaction_items', where: 'transaction_id = ?', whereArgs: [id]);

      await sql.update(
        'transactions',
        {
          ...txn.toMap(),
          // Reset to unpaid; the re-inserted payment below re-derives these via
          // the payment trigger.
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

      // Re-apply the previously-paid amount against the new total. Clamp so a
      // reduced total never carries a paid amount greater than itself; the
      // surplus has already been refunded to the account by _reversePayments.
      final reapply = priorPaid.clamp(0, txn.totalAmount).toDouble();
      if (reapply > 0) {
        final src = priorPayments.first;
        await sql.insert('payments', {
          'transaction_id': id,
          'account_id': src['account_id'],
          'payment_mode_id': src['payment_mode_id'],
          'amount': reapply,
          'payment_date': src['payment_date'] ?? now,
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
  /// the new sale id. The sale invoice number is minted atomically inside the
  /// conversion transaction (the [invoiceNumber] arg is ignored, kept only for
  /// caller-signature stability).
  Future<int> convertEstimateToSale(int estimateId,
      [String? invoiceNumber]) async {
    final db = await DatabaseHelper.database;
    final estimate = await getById(estimateId);
    if (estimate == null) throw StateError('Estimate not found');
    final lines = await getItems(estimateId);
    final now = DateTime.now().toIso8601String();

    return db.transaction((sql) async {
      final number = await DatabaseHelper.mintDocNumberInTxn(sql, 'sale');
      final saleId = await sql.insert('transactions', {
        ...estimate.toMap(),
        'transaction_type': 'sale',
        'transaction_number': number,
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
    });
  }

  // ─────────────────────────────────────────
  // DELIVERY CHALLAN → INVOICE
  // ─────────────────────────────────────────

  /// Converts a delivery challan into a new sale, copying its line items. Marks
  /// the challan `status = 'converted'` and links the new sale back to it.
  /// Returns the new sale id. The sale invoice number is minted atomically
  /// inside the conversion transaction (the [invoiceNumber] arg is ignored).
  Future<int> convertChallanToSale(int challanId,
      [String? invoiceNumber]) async {
    final db = await DatabaseHelper.database;
    final challan = await getById(challanId);
    if (challan == null) throw StateError('Delivery challan not found');
    final lines = await getItems(challanId);
    final now = DateTime.now().toIso8601String();

    return db.transaction((sql) async {
      final number = await DatabaseHelper.mintDocNumberInTxn(sql, 'sale');
      final saleId = await sql.insert('transactions', {
        ...challan.toMap(),
        'transaction_type': 'sale',
        'transaction_number': number,
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

    // If this is a payment_in / payment_out, it may have allocated money against
    // the party's invoices (tagged reference_number = 'PAY:<id>'). Those rows sit
    // on OTHER transactions, so they aren't caught by the delete below — reverse
    // them explicitly, restoring each invoice's balance/paid/status. (The payment
    // triggers only fire on INSERT, so deleting an allocation row does not
    // auto-restore the invoice; we do it by hand here.)
    if (type == 'payment_in' || type == 'payment_out') {
      await _reverseAllocations(sql, transactionId);
    }

    await sql.delete('payments', where: 'transaction_id = ?', whereArgs: [transactionId]);
  }

  /// Reverses the invoice allocations created by a payment_in / payment_out:
  /// finds every `payments` row tagged `reference_number = 'PAY:<receiptId>'`,
  /// adds each amount back onto its invoice's `balance_amount` (lowering
  /// `paid_amount` and re-deriving `payment_status`), then deletes the rows.
  Future<void> _reverseAllocations(Transaction sql, int receiptId) async {
    final allocs = await sql.query('payments',
        columns: ['transaction_id', 'amount'],
        where: 'reference_number = ?',
        whereArgs: [_allocRef(receiptId)]);
    for (final a in allocs) {
      final invId = a['transaction_id'] as int;
      final amount = (a['amount'] as num).toDouble();
      await sql.rawUpdate('''
        UPDATE transactions
        SET paid_amount    = paid_amount - ?,
            balance_amount = balance_amount + ?,
            payment_status = CASE
              WHEN (paid_amount - ?) >= total_amount THEN 'paid'
              WHEN (paid_amount - ?) > 0             THEN 'partial'
              ELSE 'unpaid'
            END,
            updated_at = datetime('now')
        WHERE id = ?
      ''', [amount, amount, amount, amount, invId]);
    }
    await sql.delete('payments',
        where: 'reference_number = ?', whereArgs: [_allocRef(receiptId)]);
  }

  // ─────────────────────────────────────────
  // EXPENSE / INCOME (no line items)
  // ─────────────────────────────────────────

  /// Creates a cash transaction (payment_in / payment_out / expense /
  /// other_income) with an immediate full payment (these are never on credit).
  /// Returns the new id.
  ///
  /// [mintType] — when supplied (e.g. `payment_in` / `payment_out`), the receipt
  /// number is minted atomically inside the insert transaction so two saves
  /// can't claim the same receipt number. Pass null when the number on [txn] is
  /// authoritative (expense/income, or a user-overridden receipt number).
  ///
  /// For a `payment_in` / `payment_out` with a linked party, the amount is also
  /// allocated against that party's outstanding sale / purchase invoices
  /// oldest-first (see [_allocateToOutstanding]), so recording a receipt reduces
  /// the invoice balances (and therefore the party's To Collect / To Pay).
  Future<int> createCashTransaction(
    model.Transaction txn, {
    required Payment payment,
    String? mintType,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    return db.transaction((sql) async {
      final number = mintType != null
          ? await DatabaseHelper.mintDocNumberInTxn(sql, mintType)
          : txn.transactionNumber;
      final id = await sql.insert('transactions', {
        ...txn.toMap(),
        'transaction_number': number,
        'paid_amount': 0,
        'balance_amount': txn.totalAmount,
        'payment_status': 'unpaid',
        'created_at': now,
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.abort);
      // The receipt's own payment row credits/debits the deposit account (via the
      // account-balance trigger) and marks THIS receipt paid.
      await sql.insert('payments', {...payment.toMap(), 'transaction_id': id});
      // Then apply the money against the party's open invoices so their balances
      // (and the party's To Collect / To Pay) actually drop.
      await _allocateToOutstanding(sql, id, txn, payment);
      return id;
    });
  }

  /// Marker written into `payments.reference_number` on an allocation row so it
  /// can be traced back to (and reversed with) the receipt that created it.
  static String _allocRef(int receiptId) => 'PAY:$receiptId';

  /// Applies a payment_in / payment_out amount against the linked party's
  /// outstanding sale / purchase invoices, oldest-first, so their
  /// `balance_amount` (and thus the party's To Collect / To Pay) is reduced.
  ///
  /// Each allocation is a `payments` row against the invoice with
  /// `account_id = NULL`, so it trips `trg_update_transaction_payment_status`
  /// (reduces the invoice balance) but NOT the account-balance trigger — the
  /// deposit account was already moved once by the receipt's own payment row.
  /// Every allocation row is tagged `reference_number = 'PAY:<receiptId>'` so
  /// editing / cancelling / deleting the receipt can find and reverse it (see
  /// [_reversePayments]).
  ///
  /// A no-op unless [txn] is a payment_in/out with a party and a positive
  /// amount; excess (over-payment beyond all open invoices) is simply left
  /// unallocated (the receipt still stands and credited the account).
  Future<void> _allocateToOutstanding(
    Transaction sql,
    int receiptId,
    model.Transaction txn,
    Payment payment,
  ) async {
    final partyId = txn.partyId;
    if (partyId == null) return;

    final String invoiceType;
    if (txn.transactionType == model.TxnTypes.paymentIn) {
      invoiceType = model.TxnTypes.sale;
    } else if (txn.transactionType == model.TxnTypes.paymentOut) {
      invoiceType = model.TxnTypes.purchase;
    } else {
      return;
    }

    var remaining = payment.amount;
    if (remaining <= 0) return;

    // Open invoices for this party, oldest first (FIFO).
    final invoices = await sql.rawQuery('''
      SELECT id, balance_amount
      FROM transactions
      WHERE business_id = ? AND party_id = ? AND transaction_type = ?
        AND is_deleted = 0 AND status != 'cancelled' AND balance_amount > 0
      ORDER BY transaction_date ASC, id ASC
    ''', [_businessId, partyId, invoiceType]);

    for (final inv in invoices) {
      if (remaining <= 0) break;
      final invId = inv['id'] as int;
      final balance = (inv['balance_amount'] as num).toDouble();
      final applied = remaining < balance ? remaining : balance;
      if (applied <= 0) continue;
      // account_id NULL ⇒ only the invoice-balance trigger fires, not the
      // account-balance trigger (the receipt already moved the account).
      await sql.insert('payments', {
        'transaction_id': invId,
        'account_id': null,
        'payment_mode_id': payment.paymentModeId,
        'amount': applied,
        'payment_date': payment.paymentDate,
        'reference_number': _allocRef(receiptId),
      });
      remaining -= applied;
    }
  }

  /// Updates a cash transaction (payment_in / payment_out / expense /
  /// other_income) in place, preserving its number and created_at. The old
  /// payment is reversed (account refunded) and the new one re-applied, so the
  /// account balance nets out and the payment trigger re-derives the totals.
  /// These documents have no line items.
  Future<void> updateCashTransaction(
    model.Transaction txn, {
    required Payment payment,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    final id = txn.id!;
    await db.transaction((sql) async {
      // Undo the old receipt: its account move AND its prior invoice allocations.
      await _reversePayments(sql, id);
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
      await sql.insert('payments', {...payment.toMap(), 'transaction_id': id});
      // Re-allocate the (possibly changed) amount / party against open invoices.
      await _allocateToOutstanding(sql, id, txn, payment);
    });
  }
}
