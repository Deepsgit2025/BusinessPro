// Regression test for editing a transaction that already has a payment.
//
// updateTransaction now ALWAYS allows editing: any recorded payment is reversed
// (account refunded) and re-applied for the previously-paid amount, clamped to
// the new total. Case A asserts a paid invoice can be edited and the prior
// payment is preserved (and the surplus refunded when the total drops); Case B
// asserts the unpaid path still works.
//
// This exercises the REAL TransactionRepository against a REAL database. The
// repository hardcodes its DB handle via DatabaseHelper.database (→ _initDb →
// getApplicationDocumentsDirectory), so to run it on a host we mock the
// path_provider platform channel to point at a temp dir. _initDb then opens a
// genuine SQLite file through the real _onCreate / _onConfigure (it inits ffi
// itself on Windows/Linux), and the real createTransaction / recordPayment /
// updateTransaction run against it. No app code is modified and no SQL is
// reimplemented.

import 'dart:io';

import 'package:business_pro/core/database/database_helper.dart';
import 'package:business_pro/features/transactions/models/payment.dart';
import 'package:business_pro/features/transactions/models/transaction.dart'
    as model;
import 'package:business_pro/features/transactions/models/transaction_item.dart';
import 'package:business_pro/features/transactions/repositories/transaction_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pathProviderChannel =
      MethodChannel('plugins.flutter.io/path_provider');

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('bp_repo_edit_guard_');
    // Point getApplicationDocumentsDirectory() (and friends) at the temp dir so
    // DatabaseHelper._initDb opens a real, throwaway DB.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      // path_provider exposes several getters; the DB only needs the documents
      // directory, but answer them all with the temp dir to be safe.
      return tempDir.path;
    });
  });

  tearDown(() async {
    await DatabaseHelper.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  });

  // Builds a minimal valid sale transaction + one line item. Uses the default
  // seeded "Piece" unit and a fresh item/party/account we insert directly.
  Future<({int txnId, int itemId, int accountId})> createSale(
    TransactionRepository repo, {
    required bool withPayment,
  }) async {
    final db = await DatabaseHelper.database;

    final partyId = await db.insert('parties', {
      'business_id': 1,
      'name': 'Edit-Guard Party',
      'party_type': 'customer',
      'uuid': 'eg-party-uuid',
    });
    final accountId = await db.insert('accounts', {
      'business_id': 1,
      'name': 'Edit-Guard Account',
      'account_type': 'cash',
      'opening_balance': 0.0,
      'current_balance': 0.0,
      'uuid': 'eg-account-uuid',
    });
    final itemId = await db.insert('items', {
      'business_id': 1,
      'name': 'Edit-Guard Item',
      'unit_id': 1,
      'item_type': 'product',
      'sale_price': 100.0,
      'opening_stock': 50.0,
      'current_stock': 50.0,
      'uuid': 'eg-item-uuid',
    });

    final txn = model.Transaction(
      transactionType: model.TxnTypes.sale,
      transactionNumber: 'INV-EG-1',
      transactionDate: '2026-01-01',
      partyId: partyId,
      accountId: accountId,
      totalAmount: 1000,
    );
    final line = TransactionItem(
      itemId: itemId,
      itemName: 'Edit-Guard Item',
      quantity: 5,
      conversionFactor: 1,
      unitPrice: 200,
      totalAmount: 1000,
    );

    final id = await repo.create(
      txn,
      [line],
      initialPayment: withPayment
          ? Payment(accountId: accountId, amount: 1000, paymentDate: '2026-01-01')
          : null,
    );

    return (txnId: id, itemId: itemId, accountId: accountId);
  }

  // Reads the live header + stock + balance so a test can assert nothing moved.
  Future<({double stock, double balance, double paid, String status, int lines})>
      snapshot(int txnId, int itemId, int accountId) async {
    final db = await DatabaseHelper.database;
    final stock = (await db.query('items',
            columns: ['current_stock'], where: 'id = ?', whereArgs: [itemId]))
        .first['current_stock'] as num;
    final balance = (await db.query('accounts',
            columns: ['current_balance'],
            where: 'id = ?',
            whereArgs: [accountId]))
        .first['current_balance'] as num;
    final txnRow = (await db.query('transactions',
            columns: ['paid_amount', 'payment_status'],
            where: 'id = ?',
            whereArgs: [txnId]))
        .first;
    final lineCount = (await db.rawQuery(
            'SELECT COUNT(*) c FROM transaction_items WHERE transaction_id = ?',
            [txnId]))
        .first['c'] as int;
    return (
      stock: stock.toDouble(),
      balance: balance.toDouble(),
      paid: (txnRow['paid_amount'] as num).toDouble(),
      status: txnRow['payment_status'] as String,
      lines: lineCount,
    );
  }

  test(
      'Case A — editing a paid invoice re-applies the prior payment (clamped) '
      'and refunds the surplus to the account', () async {
    final repo = TransactionRepository();
    final ids = await createSale(repo, withPayment: true);

    // Sanity: a payment exists and the cash sale moved +1000 into the account.
    final db = await DatabaseHelper.database;
    final payCount = (await db.rawQuery(
            'SELECT COUNT(*) c FROM payments WHERE transaction_id = ?',
            [ids.txnId]))
        .first['c'] as int;
    expect(payCount, greaterThan(0));
    final before = await snapshot(ids.txnId, ids.itemId, ids.accountId);
    expect(before.balance, 1000); // money came in on the paid sale
    expect(before.paid, 1000);

    // Edit the invoice DOWN to a 600 total (3 × 200). The prior 1000 paid is
    // clamped to 600; the 400 surplus is refunded to the account.
    final editedTxn = model.Transaction(
      id: ids.txnId,
      transactionType: model.TxnTypes.sale,
      transactionNumber: 'INV-EG-1',
      transactionDate: '2026-01-01',
      accountId: ids.accountId,
      totalAmount: 600,
    );
    final editedLine = TransactionItem(
      itemId: ids.itemId,
      itemName: 'Edit-Guard Item',
      quantity: 3,
      conversionFactor: 1,
      unitPrice: 200,
      totalAmount: 600,
    );

    await expectLater(
      repo.updateTransaction(editedTxn, [editedLine]),
      completes,
    );

    final after = await snapshot(ids.txnId, ids.itemId, ids.accountId);
    // Paid clamped to the new total → fully paid at 600.
    expect(after.paid, 600);
    expect(after.status, 'paid');
    // Account nets to the new total: +1000 − 1000 (reverse) + 600 (re-apply).
    expect(after.balance, 600);
    // One replacement line; stock reflects the new quantity (50 − 3 = 47).
    expect(after.lines, 1);
    expect(after.stock, 47);
  });

  test('Case B — updateTransaction succeeds when the transaction has no payments',
      () async {
    final repo = TransactionRepository();
    final ids = await createSale(repo, withPayment: false);

    // No payments → guard inert.
    final db = await DatabaseHelper.database;
    final payCount = (await db.rawQuery(
            'SELECT COUNT(*) c FROM payments WHERE transaction_id = ?',
            [ids.txnId]))
        .first['c'] as int;
    expect(payCount, 0);

    final editedTxn = model.Transaction(
      id: ids.txnId,
      transactionType: model.TxnTypes.sale,
      transactionNumber: 'INV-EG-1',
      transactionDate: '2026-01-01',
      accountId: ids.accountId,
      totalAmount: 600,
    );
    final editedLine = TransactionItem(
      itemId: ids.itemId,
      itemName: 'Edit-Guard Item',
      quantity: 3,
      conversionFactor: 1,
      unitPrice: 200,
      totalAmount: 600,
    );

    // Must NOT throw.
    await expectLater(
      repo.updateTransaction(editedTxn, [editedLine]),
      completes,
    );

    // Spot-check the edit actually applied (the new line replaced the old one).
    final after = await snapshot(ids.txnId, ids.itemId, ids.accountId);
    expect(after.lines, 1);
    expect(after.status, 'unpaid'); // edit resets payment fields to unpaid
  });
}
