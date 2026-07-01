// Regression tests for the atomic document-number minting that replaced the
// old peek-at-open / consume-after-commit scheme. The bug these guard against:
// two saves claiming the SAME number (duplicate INV/PUR/EST/CN/receipt) because
// the number was reserved only after the insert committed, or never reserved at
// all (estimate/challan/returns used a racy count(*)+1).
//
// Guarantees verified:
//   • repo.create(..., mintType:) stamps a freshly reserved number on the row,
//     ignoring whatever number the caller put on the Transaction.
//   • Sequential creates of the same type never repeat a number.
//   • Concurrent (Future.wait) creates of the same type get distinct numbers
//     (the read-modify-write of the counter is inside the insert transaction).
//   • Count-derived types (estimate, sale_return, …) each hold an independent
//     reserved counter and seed past the highest existing number.
//   • mintType:null keeps the caller's number verbatim (override path).
//   • peekDocNumberForType previews the same number the next mint will produce.
//
// Runs the REAL repository + DatabaseHelper against a throwaway SQLite file.

import 'dart:io';

import 'package:business_pro/core/database/database_helper.dart';
import 'package:business_pro/features/transactions/models/transaction.dart'
    as model;
import 'package:business_pro/features/transactions/models/transaction_item.dart';
import 'package:business_pro/features/transactions/models/payment.dart';
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
    tempDir = await Directory.systemTemp.createTemp('bp_mint_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            pathProviderChannel, (call) async => tempDir.path);
  });

  tearDown(() async {
    await DatabaseHelper.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {/* best-effort */}
  });

  model.Transaction txnOf(String type, {String number = 'IGNORED'}) =>
      model.Transaction(
        transactionType: type,
        transactionNumber: number,
        transactionDate: '2026-01-01',
        totalAmount: 100,
      );

  List<TransactionItem> oneLine() => [
        TransactionItem(
          itemName: 'X',
          quantity: 1,
          conversionFactor: 1,
          unitPrice: 100,
          totalAmount: 100,
        ),
      ];

  // The number actually stored on a saved row.
  Future<String> numberOf(TransactionRepository repo, int id) async =>
      (await repo.getById(id))!.transactionNumber;

  test('mintType overrides the caller-supplied number with a reserved one',
      () async {
    final repo = TransactionRepository();
    await DatabaseHelper.updateBusiness(
        {'invoice_prefix': 'INV', 'invoice_counter': 1});

    // Caller put a bogus number on the txn; mint must replace it.
    final id = await repo.create(txnOf(model.TxnTypes.sale, number: 'BOGUS'),
        oneLine(), mintType: model.TxnTypes.sale);
    expect(await numberOf(repo, id), endsWith('INV-0001'));
  });

  test('sequential sale creates never repeat a number', () async {
    final repo = TransactionRepository();
    await DatabaseHelper.updateBusiness(
        {'invoice_prefix': 'INV', 'invoice_counter': 1});

    final numbers = <String>[];
    for (var i = 0; i < 5; i++) {
      final id = await repo.create(
          txnOf(model.TxnTypes.sale), oneLine(),
          mintType: model.TxnTypes.sale);
      numbers.add(await numberOf(repo, id));
    }
    expect(numbers.toSet().length, 5, reason: 'all numbers distinct');
    expect(numbers.last, endsWith('INV-0005'));
  });

  test('concurrent creates of the same type get distinct numbers', () async {
    final repo = TransactionRepository();
    await DatabaseHelper.updateBusiness(
        {'invoice_prefix': 'INV', 'invoice_counter': 1});

    // Fire several creates without awaiting between them — the old design would
    // hand them all the same peeked number.
    final ids = await Future.wait([
      for (var i = 0; i < 6; i++)
        repo.create(txnOf(model.TxnTypes.sale), oneLine(),
            mintType: model.TxnTypes.sale),
    ]);
    final numbers = {for (final id in ids) await numberOf(repo, id)};
    expect(numbers.length, 6, reason: 'no two concurrent saves share a number');
  });

  test('estimate and sale counters are independent reserved sequences',
      () async {
    final repo = TransactionRepository();
    await DatabaseHelper.updateBusiness(
        {'invoice_prefix': 'INV', 'invoice_counter': 1});

    final e1 = await repo.create(txnOf(model.TxnTypes.estimate), oneLine(),
        mintType: model.TxnTypes.estimate);
    final e2 = await repo.create(txnOf(model.TxnTypes.estimate), oneLine(),
        mintType: model.TxnTypes.estimate);
    final s1 = await repo.create(txnOf(model.TxnTypes.sale), oneLine(),
        mintType: model.TxnTypes.sale);

    expect(await numberOf(repo, e1), endsWith('EST-0001'));
    expect(await numberOf(repo, e2), endsWith('EST-0002'),
        reason: 'two estimates must not collide');
    expect(await numberOf(repo, s1), endsWith('INV-0001'),
        reason: 'sale sequence is independent of estimates');
  });

  test('credit-note (sale_return) numbers are reserved, never duplicated',
      () async {
    final repo = TransactionRepository();
    final c1 = await repo.create(txnOf(model.TxnTypes.saleReturn), oneLine(),
        mintType: model.TxnTypes.saleReturn);
    final c2 = await repo.create(txnOf(model.TxnTypes.saleReturn), oneLine(),
        mintType: model.TxnTypes.saleReturn);
    expect(await numberOf(repo, c1), endsWith('CN 1'));
    expect(await numberOf(repo, c2), endsWith('CN 2'));
  });

  test('count-derived seed steps past the highest existing number', () async {
    final repo = TransactionRepository();
    // Pre-existing estimate numbered EST-0009 (e.g. imported / overridden).
    await repo.create(txnOf(model.TxnTypes.estimate, number: 'EST-0009'),
        oneLine());
    // First minted estimate must be 10, not 2 (count would have said 2).
    final id = await repo.create(txnOf(model.TxnTypes.estimate), oneLine(),
        mintType: model.TxnTypes.estimate);
    expect(await numberOf(repo, id), endsWith('EST-0010'));
  });

  test('mintType:null keeps the caller number verbatim (override path)',
      () async {
    final repo = TransactionRepository();
    final id = await repo.create(
        txnOf(model.TxnTypes.sale, number: 'K/100'), oneLine());
    expect(await numberOf(repo, id), equals('K/100'));
  });

  test('peekDocNumberForType previews the number the next mint produces',
      () async {
    final repo = TransactionRepository();
    await DatabaseHelper.updateBusiness(
        {'invoice_prefix': 'INV', 'invoice_counter': 1});

    final preview = await DatabaseHelper.peekDocNumberForType(model.TxnTypes.sale);
    final id = await repo.create(txnOf(model.TxnTypes.sale), oneLine(),
        mintType: model.TxnTypes.sale);
    expect(await numberOf(repo, id), equals(preview),
        reason: 'preview must match what is saved');
    // And peeking again (idempotent) now shows the NEXT number.
    final preview2 =
        await DatabaseHelper.peekDocNumberForType(model.TxnTypes.sale);
    expect(preview2, isNot(equals(preview)));
  });

  test('payment_in / payment_out share the receipt counter, never duplicate',
      () async {
    final repo = TransactionRepository();
    await DatabaseHelper.updateBusiness({'receipt_counter': 1});

    final r1 = await repo.createCashTransaction(
      txnOf(model.TxnTypes.paymentIn),
      payment: _pay(),
      mintType: model.TxnTypes.paymentIn,
    );
    final r2 = await repo.createCashTransaction(
      txnOf(model.TxnTypes.paymentOut),
      payment: _pay(),
      mintType: model.TxnTypes.paymentOut,
    );
    final n1 = await numberOf(repo, r1);
    final n2 = await numberOf(repo, r2);
    expect(n1, endsWith('1'));
    expect(n2, endsWith('2'),
        reason: 'receipt counter is shared and monotonic across in/out');
    expect(n1, isNot(equals(n2)));
  });
}

Payment _pay() => Payment(amount: 100, paymentDate: '2026-01-01');
