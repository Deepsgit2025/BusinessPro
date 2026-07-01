// Tests for the user-editable document number guard (numberExists), used when a
// user overrides an invoice/receipt number (e.g. "K/100") on the entry screen.
//
// numberExists(number, {excludeId}) must:
//   • return true when another non-deleted transaction already uses the number,
//   • return false for a free number,
//   • ignore the row identified by excludeId (so re-saving its own number on an
//     edit isn't flagged as a clash),
//   • ignore soft-deleted rows.
//
// Runs the REAL TransactionRepository against a REAL throwaway SQLite DB, mocking
// path_provider so DatabaseHelper opens a temp file (same harness as the edit
// test).

import 'dart:io';

import 'package:business_pro/core/database/database_helper.dart';
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
    tempDir = await Directory.systemTemp.createTemp('bp_num_override_');
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

  // Creates a sale carrying [number] and returns its id.
  Future<int> createSale(TransactionRepository repo, String number) {
    final txn = model.Transaction(
      transactionType: model.TxnTypes.sale,
      transactionNumber: number,
      transactionDate: '2026-01-01',
      totalAmount: 100,
    );
    final line = TransactionItem(
      itemName: 'X',
      quantity: 1,
      conversionFactor: 1,
      unitPrice: 100,
      totalAmount: 100,
    );
    return repo.create(txn, [line]);
  }

  test('numberExists detects a used number and clears a free one', () async {
    final repo = TransactionRepository();
    await createSale(repo, 'K/100');

    expect(await repo.numberExists('K/100'), isTrue);
    expect(await repo.numberExists('K/101'), isFalse);
  });

  test('numberExists ignores the row being edited (excludeId)', () async {
    final repo = TransactionRepository();
    final id = await createSale(repo, 'K/100');

    // Without excludeId the row clashes with itself; with it, it does not.
    expect(await repo.numberExists('K/100'), isTrue);
    expect(await repo.numberExists('K/100', excludeId: id), isFalse);
  });

  test('numberExists ignores soft-deleted rows', () async {
    final repo = TransactionRepository();
    final id = await createSale(repo, 'K/100');
    await repo.softDelete(id);

    // The number is free again once its only holder is soft-deleted.
    expect(await repo.numberExists('K/100'), isFalse);
  });
}
