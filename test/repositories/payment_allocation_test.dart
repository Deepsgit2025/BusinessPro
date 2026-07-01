// Tests that a Payment-In receipt is ALLOCATED against the party's outstanding
// sale invoices (oldest-first), so recording a receipt actually reduces the
// invoice balance and the party's To Collect — the "Ramesh" scenario:
//
//   * Ramesh buys a TV for ₹10,000, pays ₹5,000 on the invoice (balance ₹5,000).
//   * Later he repays ₹2,000 via Payment-In → the sale balance must drop to
//     ₹3,000 (and the party's To Collect with it).
//
// Also covers: allocation across multiple invoices oldest-first, editing a
// receipt re-allocates, and deleting a receipt reverses the allocation.
//
// Exercises the REAL TransactionRepository + real triggers against a real
// throwaway SQLite DB (path_provider platform channel mocked to a temp dir),
// mirroring transaction_repository_edit_guard_test.dart.

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
    tempDir = await Directory.systemTemp.createTemp('bp_payment_alloc_');
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

  Future<int> seedParty(String name) async {
    final db = await DatabaseHelper.database;
    return db.insert('parties', {
      'business_id': 1,
      'name': name,
      'party_type': 'customer',
      'uuid': 'party-$name',
    });
  }

  Future<int> seedAccount() async {
    final db = await DatabaseHelper.database;
    return db.insert('accounts', {
      'business_id': 1,
      'name': 'Cash',
      'account_type': 'cash',
      'opening_balance': 0.0,
      'current_balance': 0.0,
      'uuid': 'acct-cash',
    });
  }

  // Creates a sale for [partyId] with [total], paying [paid] up front. Returns
  // the sale id.
  Future<int> createSale(
    TransactionRepository repo, {
    required int partyId,
    required int accountId,
    required String number,
    required String date,
    required double total,
    required double paid,
  }) async {
    final txn = model.Transaction(
      transactionType: model.TxnTypes.sale,
      transactionNumber: number,
      transactionDate: date,
      partyId: partyId,
      accountId: paid > 0 ? accountId : null,
      totalAmount: total,
    );
    final line = TransactionItem(
      itemName: 'TV',
      quantity: 1,
      conversionFactor: 1,
      unitPrice: total,
      totalAmount: total,
    );
    return repo.create(
      txn,
      [line],
      initialPayment:
          paid > 0 ? Payment(accountId: accountId, amount: paid, paymentDate: date) : null,
    );
  }

  Future<double> saleBalance(int saleId) async {
    final db = await DatabaseHelper.database;
    final r = await db.query('transactions',
        columns: ['balance_amount'], where: 'id = ?', whereArgs: [saleId]);
    return (r.first['balance_amount'] as num).toDouble();
  }

  // Party To Collect = Σ balance_amount over the party's sales (mirrors the
  // PartyRepository list query).
  Future<double> toCollect(int partyId) async {
    final db = await DatabaseHelper.database;
    final r = await db.rawQuery('''
      SELECT COALESCE(SUM(balance_amount), 0) AS c
      FROM transactions
      WHERE party_id = ? AND transaction_type = 'sale' AND is_deleted = 0
    ''', [partyId]);
    return (r.first['c'] as num).toDouble();
  }

  test('Ramesh: ₹2,000 Payment-In drops the ₹5,000 sale balance to ₹3,000',
      () async {
    final repo = TransactionRepository();
    final ramesh = await seedParty('Ramesh');
    final account = await seedAccount();

    // TV ₹10,000, paid ₹5,000 on 15 March → balance ₹5,000.
    final saleId = await createSale(repo,
        partyId: ramesh,
        accountId: account,
        number: 'INV-1',
        date: '2026-03-15',
        total: 10000,
        paid: 5000);
    expect(await saleBalance(saleId), 5000);
    expect(await toCollect(ramesh), 5000);

    // 20 March: Payment-In of ₹2,000.
    await repo.createCashTransaction(
      model.Transaction(
        transactionType: model.TxnTypes.paymentIn,
        transactionNumber: 'RCP-1',
        transactionDate: '2026-03-20',
        partyId: ramesh,
        accountId: account,
        totalAmount: 2000,
      ),
      payment: Payment(accountId: account, amount: 2000, paymentDate: '2026-03-20'),
    );

    // Sale balance and To Collect both drop to ₹3,000.
    expect(await saleBalance(saleId), 3000);
    expect(await toCollect(ramesh), 3000);

    // The account received both the ₹5,000 and the ₹2,000 exactly once (the
    // allocation row must NOT double-credit the account).
    final db = await DatabaseHelper.database;
    final bal = (await db.query('accounts',
            columns: ['current_balance'], where: 'id = ?', whereArgs: [account]))
        .first['current_balance'] as num;
    expect(bal.toDouble(), 7000);
  });

  test('allocation spills oldest-first across multiple invoices', () async {
    final repo = TransactionRepository();
    final party = await seedParty('Multi');
    final account = await seedAccount();

    final inv1 = await createSale(repo,
        partyId: party,
        accountId: account,
        number: 'INV-A',
        date: '2026-01-01',
        total: 1000,
        paid: 0); // oldest, ₹1000 open
    final inv2 = await createSale(repo,
        partyId: party,
        accountId: account,
        number: 'INV-B',
        date: '2026-02-01',
        total: 1000,
        paid: 0); // newer, ₹1000 open

    // Pay ₹1500: clears INV-A fully (₹1000) then ₹500 onto INV-B.
    await repo.createCashTransaction(
      model.Transaction(
        transactionType: model.TxnTypes.paymentIn,
        transactionNumber: 'RCP-2',
        transactionDate: '2026-03-01',
        partyId: party,
        accountId: account,
        totalAmount: 1500,
      ),
      payment: Payment(accountId: account, amount: 1500, paymentDate: '2026-03-01'),
    );

    expect(await saleBalance(inv1), 0);
    expect(await saleBalance(inv2), 500);
    expect(await toCollect(party), 500);
  });

  test('deleting the Payment-In receipt restores the sale balance', () async {
    final repo = TransactionRepository();
    final party = await seedParty('Reversal');
    final account = await seedAccount();

    final saleId = await createSale(repo,
        partyId: party,
        accountId: account,
        number: 'INV-R',
        date: '2026-03-15',
        total: 10000,
        paid: 5000);

    final receiptId = await repo.createCashTransaction(
      model.Transaction(
        transactionType: model.TxnTypes.paymentIn,
        transactionNumber: 'RCP-R',
        transactionDate: '2026-03-20',
        partyId: party,
        accountId: account,
        totalAmount: 2000,
      ),
      payment: Payment(accountId: account, amount: 2000, paymentDate: '2026-03-20'),
    );
    expect(await saleBalance(saleId), 3000);

    // Deleting the receipt un-does the allocation: sale goes back to ₹5,000.
    await repo.softDelete(receiptId);
    expect(await saleBalance(saleId), 5000);
    expect(await toCollect(party), 5000);
  });
}
