// Verifies the party Statement ledger (#9): a bill shows at its full total AND
// every real payment against the party shows as a separate debit/credit — the
// amount paid at a purchase's creation as well as a later payment-out receipt —
// so the running balance reflects what's actually owed.
//
// Reported scenario: purchase ₹10000, ₹5000 paid at entry, ₹4000 payment-out
// later ⇒ credit 10000, debit 5000, debit 4000 ⇒ you still owe ₹1000.
//
// Runs the REAL repositories against a REAL SQLite DB (path_provider mocked to a
// temp dir), same harness as transaction_repository_edit_guard_test.dart.

import 'dart:io';

import 'package:business_pro/core/database/database_helper.dart';
import 'package:business_pro/features/parties/repositories/party_repository.dart';
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
    tempDir = await Directory.systemTemp.createTemp('bp_party_ledger_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      return tempDir.path;
    });
  });

  tearDown(() async {
    await DatabaseHelper.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  test(
      'ledger shows the bill + the amount paid at entry + a later payment-out',
      () async {
    final txnRepo = TransactionRepository();
    final partyRepo = PartyRepository();
    final db = await DatabaseHelper.database;

    final partyId = await db.insert('parties', {
      'business_id': 1,
      'name': 'Ledger Supplier',
      'party_type': 'supplier',
      'uuid': 'ledger-party-uuid',
    });
    final accountId = await db.insert('accounts', {
      'business_id': 1,
      'name': 'Ledger Account',
      'account_type': 'cash',
      'opening_balance': 0.0,
      'current_balance': 0.0,
      'uuid': 'ledger-account-uuid',
    });
    final itemId = await db.insert('items', {
      'business_id': 1,
      'name': 'Ledger Item',
      'unit_id': 1,
      'item_type': 'product',
      'purchase_price': 1000.0,
      'opening_stock': 0.0,
      'current_stock': 0.0,
      'uuid': 'ledger-item-uuid',
    });

    // Purchase ₹10000 with ₹5000 paid at entry (date 01-01).
    await txnRepo.create(
      model.Transaction(
        transactionType: model.TxnTypes.purchase,
        transactionNumber: 'PUR-001',
        transactionDate: '2026-01-01',
        partyId: partyId,
        accountId: accountId,
        totalAmount: 10000,
      ),
      [
        TransactionItem(
          itemId: itemId,
          itemName: 'Ledger Item',
          quantity: 10,
          conversionFactor: 1,
          unitPrice: 1000,
          totalAmount: 10000,
        ),
      ],
      initialPayment:
          Payment(accountId: accountId, amount: 5000, paymentDate: '2026-01-01'),
    );

    // A later payment-out of ₹4000 to the same supplier (date 01-02).
    await txnRepo.createCashTransaction(
      model.Transaction(
        transactionType: model.TxnTypes.paymentOut,
        transactionNumber: 'PAY-OUT-001',
        transactionDate: '2026-01-02',
        partyId: partyId,
        accountId: accountId,
        totalAmount: 4000,
      ),
      payment:
          Payment(accountId: accountId, amount: 4000, paymentDate: '2026-01-02'),
    );

    final ledger = await partyRepo.ledger(partyId);

    // Three events: the bill, the entry payment, the payment-out. (The internal
    // allocation row the payment-out creates against the purchase is excluded.)
    expect(ledger.length, 3);

    double debit(Map<String, dynamic> r) => (r['debit'] as num).toDouble();
    double credit(Map<String, dynamic> r) => (r['credit'] as num).toDouble();

    // Ordered by date, then bill-before-payment on the same date.
    expect(ledger[0]['kind'], 'bill');
    expect(credit(ledger[0]), 10000); // purchase raises what you owe
    expect(debit(ledger[0]), 0);

    expect(ledger[1]['kind'], 'payment');
    expect(debit(ledger[1]), 5000); // paid at entry
    expect(credit(ledger[1]), 0);

    expect(ledger[2]['kind'], 'payment');
    expect(debit(ledger[2]), 4000); // payment-out
    expect(credit(ledger[2]), 0);

    // Running balance folded from 0: −10000 +5000 +4000 = −1000 (you owe 1000).
    final net = ledger.fold<double>(0, (s, r) => s + debit(r) - credit(r));
    expect(net, -1000);
  });
}
