import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:business_pro/features/transactions/models/transaction_item.dart';
import 'package:business_pro/features/transactions/utils/txn_calc.dart';

/// Phase 3 calculation correctness. Focuses on the spec's flagged risk areas:
/// tax-inclusive pricing, GST split (intra vs inter state), discounts, and
/// round-off.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  TransactionItem line({
    double qty = 1,
    double price = 0,
    String discType = 'none',
    double discValue = 0,
    double taxRate = 0,
    bool inclusive = false,
  }) =>
      TransactionItem(
        itemName: 'X',
        quantity: qty,
        unitPrice: price,
        discountType: discType,
        discountValue: discValue,
        taxRate: taxRate,
        taxInclusive: inclusive,
      );

  group('line calculation', () {
    test('plain line, no tax/discount', () {
      final c = TxnCalc.computeLine(line(qty: 3, price: 100), interState: false);
      expect(c.taxableAmount, 300);
      expect(c.taxAmount, 0);
      expect(c.totalAmount, 300);
    });

    test('percent discount reduces taxable', () {
      final c = TxnCalc.computeLine(
          line(qty: 2, price: 100, discType: 'percent', discValue: 10),
          interState: false);
      expect(c.discountAmount, 20);
      expect(c.taxableAmount, 180);
      expect(c.totalAmount, 180);
    });

    test('flat discount is clamped to line total', () {
      final c = TxnCalc.computeLine(
          line(qty: 1, price: 50, discType: 'flat', discValue: 80),
          interState: false);
      expect(c.discountAmount, 50);
      expect(c.taxableAmount, 0);
    });

    test('GST 18% intra-state splits into CGST + SGST', () {
      final c = TxnCalc.computeLine(line(qty: 1, price: 1000, taxRate: 18),
          interState: false);
      expect(c.taxAmount, 180);
      expect(c.cgstAmount, 90);
      expect(c.sgstAmount, 90);
      expect(c.igstAmount, 0);
      expect(c.totalAmount, 1180);
    });

    test('GST 18% inter-state is all IGST', () {
      final c = TxnCalc.computeLine(line(qty: 1, price: 1000, taxRate: 18),
          interState: true);
      expect(c.cgstAmount, 0);
      expect(c.sgstAmount, 0);
      expect(c.igstAmount, 180);
      expect(c.totalAmount, 1180);
    });

    test('tax-inclusive price extracts tax from within', () {
      // ₹118 inclusive of 18% → ₹100 net + ₹18 tax, total stays ₹118.
      final c = TxnCalc.computeLine(
          line(qty: 1, price: 118, taxRate: 18, inclusive: true),
          interState: false);
      expect(c.taxAmount, closeTo(18, 0.001));
      expect(c.taxableAmount, closeTo(100, 0.001));
      expect(c.totalAmount, closeTo(118, 0.001));
    });
  });

  group('totals + round-off', () {
    test('aggregates lines and snaps total to nearest rupee', () {
      // 2 lines, exclusive GST 5% producing a fractional total.
      final totals = TxnCalc.totals([
        line(qty: 1, price: 99.50, taxRate: 5),
        line(qty: 1, price: 49.90, taxRate: 5),
      ], interState: false);

      // taxable = 149.40, tax = 7.47 → 156.87 → rounds to 157.
      expect(totals.taxableAmount, closeTo(149.40, 0.001));
      expect(totals.taxAmount, closeTo(7.47, 0.001));
      expect(totals.total, 157);
      expect(totals.roundOff, closeTo(0.13, 0.001));
    });

    test('inter-state totals report IGST only', () {
      final totals = TxnCalc.totals([
        line(qty: 1, price: 1000, taxRate: 18),
      ], interState: true);
      expect(totals.cgstAmount, 0);
      expect(totals.sgstAmount, 0);
      expect(totals.igstAmount, 180);
      expect(totals.total, 1180);
    });
  });

  // Verifies the trigger contract the repository relies on: inserting a payment
  // (not a manual UPDATE) is what drives paid/balance/status and the account
  // balance. Mirrors the production triggers in an in-memory DB.
  group('payment trigger contract', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(inMemoryDatabasePath, version: 1,
          onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            current_balance REAL DEFAULT 0, updated_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            transaction_type TEXT,
            total_amount REAL DEFAULT 0,
            paid_amount REAL DEFAULT 0,
            balance_amount REAL DEFAULT 0,
            payment_status TEXT DEFAULT 'unpaid', updated_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE payments (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            transaction_id INTEGER, account_id INTEGER,
            amount REAL NOT NULL, created_at TEXT DEFAULT (datetime('now'))
          )
        ''');
        await db.execute('''
          CREATE TRIGGER trg_update_transaction_payment_status
          AFTER INSERT ON payments
          BEGIN
            UPDATE transactions
            SET paid_amount = paid_amount + NEW.amount,
                balance_amount = total_amount - (paid_amount + NEW.amount),
                payment_status = CASE
                  WHEN (paid_amount + NEW.amount) >= total_amount THEN 'paid'
                  WHEN (paid_amount + NEW.amount) > 0 THEN 'partial'
                  ELSE 'unpaid' END
            WHERE id = NEW.transaction_id;
          END
        ''');
        await db.execute('''
          CREATE TRIGGER trg_account_balance_increase
          AFTER INSERT ON payments
          WHEN NEW.account_id IS NOT NULL
            AND (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id)
                IN ('sale','payment_in','other_income')
          BEGIN
            UPDATE accounts SET current_balance = current_balance + NEW.amount
            WHERE id = NEW.account_id;
          END
        ''');
      });
      await db.insert('accounts', {'id': 1, 'current_balance': 0});
      await db.insert('transactions', {
        'id': 1,
        'transaction_type': 'sale',
        'total_amount': 1000,
        'balance_amount': 1000,
        'payment_status': 'unpaid',
      });
    });

    tearDown(() => db.close());

    Future<Map<String, Object?>> txn() async =>
        (await db.query('transactions', where: 'id = 1')).single;

    test('partial payment sets partial status and moves account balance',
        () async {
      await db.insert('payments',
          {'transaction_id': 1, 'account_id': 1, 'amount': 400});
      final t = await txn();
      expect(t['paid_amount'], 400);
      expect(t['balance_amount'], 600);
      expect(t['payment_status'], 'partial');
      final acc = (await db.query('accounts', where: 'id = 1')).single;
      expect(acc['current_balance'], 400);
    });

    test('payments accumulate to paid', () async {
      await db.insert('payments',
          {'transaction_id': 1, 'account_id': 1, 'amount': 400});
      await db.insert('payments',
          {'transaction_id': 1, 'account_id': 1, 'amount': 600});
      final t = await txn();
      expect(t['paid_amount'], 1000);
      expect(t['balance_amount'], 0);
      expect(t['payment_status'], 'paid');
    });
  });
}
