// CORE test group: the v10 sync guards.
//
// WHAT THIS LOCKS: all seven effect triggers carry COALESCE(NEW.is_synced,0)=0.
//   - A LOCAL row (is_synced = 0) applies its stock/balance/status effect once.
//   - A SYNCED row (is_synced = 1, arriving from the other device) applies
//     NOTHING — the originating device already applied it.
// This is the doubling bug v10 fixed; it must stay fixed.
//
// These triggers fire on raw INSERTs, so every test here drives the REAL DB
// handle with raw SQL inserts (via the harness helpers) — never the
// repositories. We are testing the trigger, not repo logic.

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'migration_harness.dart';

void main() {
  setUpAll(initMigrationHarness);
  tearDown(disposeOpenedDatabases);

  /// Fresh, seeded v13 DB per test for full isolation.
  Future<({Database db, SeedRefs refs})> freshSeededDb() async {
    final db = await openAtVersion(currentSchemaVersion);
    addTearDown(db.close);
    final refs = await seedMinimal(db);
    return (db: db, refs: refs);
  }

  // ───────────────────────────────────────────────────────────────────────
  // GROUP 4 — STOCK triggers
  //   trg_stock_decrease_on_sale / _increase_on_sale_return /
  //   _increase_on_purchase / _decrease_on_purchase_return
  // ───────────────────────────────────────────────────────────────────────
  group('Group 4 — stock triggers', () {
    /// Inserts a header of [type] + one line (qty, factor, is_synced) and
    /// returns the item's current_stock afterward.
    Future<double> stockAfterLine(
      Database db,
      SeedRefs refs, {
      required String type,
      required double quantity,
      required int isSynced,
      double conversionFactor = 1,
    }) async {
      final txnId = await insertTransaction(db, type: type, isSynced: 0);
      await insertTransactionItem(
        db,
        transactionId: txnId,
        itemId: refs.itemId,
        quantity: quantity,
        conversionFactor: conversionFactor,
        itemUnitId: refs.itemUnitId,
        isSynced: isSynced,
      );
      return readNum(db, 'items', 'current_stock', refs.itemId);
    }

    test('I4.1 local sale decreases stock by qty', () async {
      final f = await freshSeededDb();
      final stock = await stockAfterLine(f.db, f.refs,
          type: 'sale', quantity: 10, isSynced: 0);
      expect(stock, f.refs.itemOpeningStock - 10);
    });

    test('I4.2 synced sale leaves stock UNCHANGED (the guard)', () async {
      final f = await freshSeededDb();
      final stock = await stockAfterLine(f.db, f.refs,
          type: 'sale', quantity: 10, isSynced: 1);
      expect(stock, f.refs.itemOpeningStock);
    });

    test('sale_return — local increases, synced no-ops', () async {
      final local = await freshSeededDb();
      expect(
        await stockAfterLine(local.db, local.refs,
            type: 'sale_return', quantity: 10, isSynced: 0),
        local.refs.itemOpeningStock + 10,
      );

      final synced = await freshSeededDb();
      expect(
        await stockAfterLine(synced.db, synced.refs,
            type: 'sale_return', quantity: 10, isSynced: 1),
        synced.refs.itemOpeningStock,
      );
    });

    test('purchase — local increases, synced no-ops', () async {
      final local = await freshSeededDb();
      expect(
        await stockAfterLine(local.db, local.refs,
            type: 'purchase', quantity: 10, isSynced: 0),
        local.refs.itemOpeningStock + 10,
      );

      final synced = await freshSeededDb();
      expect(
        await stockAfterLine(synced.db, synced.refs,
            type: 'purchase', quantity: 10, isSynced: 1),
        synced.refs.itemOpeningStock,
      );
    });

    test('purchase_return — local decreases, synced no-ops', () async {
      final local = await freshSeededDb();
      expect(
        await stockAfterLine(local.db, local.refs,
            type: 'purchase_return', quantity: 10, isSynced: 0),
        local.refs.itemOpeningStock - 10,
      );

      final synced = await freshSeededDb();
      expect(
        await stockAfterLine(synced.db, synced.refs,
            type: 'purchase_return', quantity: 10, isSynced: 1),
        synced.refs.itemOpeningStock,
      );
    });

    test('I4.7 conversion_factor: qty 2 × factor 12 moves stock by 24', () async {
      final f = await freshSeededDb();
      final stock = await stockAfterLine(f.db, f.refs,
          type: 'sale', quantity: 2, conversionFactor: 12, isSynced: 0);
      expect(stock, f.refs.itemOpeningStock - 24);
      // Guard: it must NOT have moved by the raw quantity (2).
      expect(stock, isNot(f.refs.itemOpeningStock - 2));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // GROUP 4 — ACCOUNT BALANCE triggers
  //   trg_account_balance_increase / trg_account_balance_decrease
  // ───────────────────────────────────────────────────────────────────────
  group('Group 4 — account balance triggers', () {
    Future<double> balanceAfterPayment(
      Database db,
      SeedRefs refs, {
      required String type,
      required double amount,
      required int isSynced,
    }) async {
      final txnId = await insertTransaction(db,
          type: type, isSynced: 0, totalAmount: amount);
      await insertPayment(db,
          transactionId: txnId,
          accountId: refs.accountId,
          amount: amount,
          isSynced: isSynced);
      return readNum(db, 'accounts', 'current_balance', refs.accountId);
    }

    test('I4.3 local payment increases balance on sale/payment_in/other_income',
        () async {
      for (final type in ['sale', 'payment_in', 'other_income']) {
        final f = await freshSeededDb();
        final bal = await balanceAfterPayment(f.db, f.refs,
            type: type, amount: 200, isSynced: 0);
        expect(bal, f.refs.accountOpeningBalance + 200,
            reason: '$type should increase the account balance');
      }
    });

    test('I4.3 local payment decreases balance on purchase/payment_out/expense',
        () async {
      for (final type in ['purchase', 'payment_out', 'expense']) {
        final f = await freshSeededDb();
        final bal = await balanceAfterPayment(f.db, f.refs,
            type: type, amount: 200, isSynced: 0);
        expect(bal, f.refs.accountOpeningBalance - 200,
            reason: '$type should decrease the account balance');
      }
    });

    test('I4.4 synced payment leaves balance UNCHANGED (increase side)',
        () async {
      final f = await freshSeededDb();
      final bal = await balanceAfterPayment(f.db, f.refs,
          type: 'sale', amount: 200, isSynced: 1);
      expect(bal, f.refs.accountOpeningBalance);
    });

    test('I4.4 synced payment leaves balance UNCHANGED (decrease side)',
        () async {
      final f = await freshSeededDb();
      final bal = await balanceAfterPayment(f.db, f.refs,
          type: 'purchase', amount: 200, isSynced: 1);
      expect(bal, f.refs.accountOpeningBalance);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // GROUP 4 — PAYMENT STATUS trigger
  //   trg_update_transaction_payment_status
  // ───────────────────────────────────────────────────────────────────────
  group('Group 4 — payment status trigger', () {
    test('I4.5 unpaid baseline before any payment', () async {
      final f = await freshSeededDb();
      final txnId = await insertTransaction(f.db,
          type: 'sale', isSynced: 0, totalAmount: 1000, balanceAmount: 1000);
      expect(await readNum(f.db, 'transactions', 'paid_amount', txnId), 0);
      expect(await readStr(f.db, 'transactions', 'payment_status', txnId),
          'unpaid');
    });

    test('I4.5 local partial payment → partial, balance = total - paid',
        () async {
      final f = await freshSeededDb();
      final txnId = await insertTransaction(f.db,
          type: 'sale', isSynced: 0, totalAmount: 1000, balanceAmount: 1000);
      await insertPayment(f.db,
          transactionId: txnId,
          accountId: f.refs.accountId,
          amount: 400,
          isSynced: 0);
      expect(await readNum(f.db, 'transactions', 'paid_amount', txnId), 400);
      expect(await readNum(f.db, 'transactions', 'balance_amount', txnId), 600);
      expect(await readStr(f.db, 'transactions', 'payment_status', txnId),
          'partial');
    });

    test('I4.5 local full payment → paid, balance = 0', () async {
      final f = await freshSeededDb();
      final txnId = await insertTransaction(f.db,
          type: 'sale', isSynced: 0, totalAmount: 1000, balanceAmount: 1000);
      await insertPayment(f.db,
          transactionId: txnId,
          accountId: f.refs.accountId,
          amount: 1000,
          isSynced: 0);
      expect(await readNum(f.db, 'transactions', 'paid_amount', txnId), 1000);
      expect(await readNum(f.db, 'transactions', 'balance_amount', txnId), 0);
      expect(await readStr(f.db, 'transactions', 'payment_status', txnId),
          'paid');
    });

    test('I4.6 synced payment → paid_amount/balance/status UNCHANGED', () async {
      final f = await freshSeededDb();
      // Seed the header as already "unpaid" with the full balance outstanding.
      final txnId = await insertTransaction(f.db,
          type: 'sale',
          isSynced: 0,
          totalAmount: 1000,
          paidAmount: 0,
          balanceAmount: 1000,
          paymentStatus: 'unpaid');
      await insertPayment(f.db,
          transactionId: txnId,
          accountId: f.refs.accountId,
          amount: 1000,
          isSynced: 1); // synced payment — guard must suppress derivation.

      expect(await readNum(f.db, 'transactions', 'paid_amount', txnId), 0);
      expect(await readNum(f.db, 'transactions', 'balance_amount', txnId), 1000);
      expect(await readStr(f.db, 'transactions', 'payment_status', txnId),
          'unpaid');
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // GROUP 5 — TRIGGER INVENTORY
  // ───────────────────────────────────────────────────────────────────────
  group('Group 5 — trigger inventory', () {
    const effectTriggers = [
      'trg_stock_decrease_on_sale',
      'trg_stock_increase_on_sale_return',
      'trg_stock_increase_on_purchase',
      'trg_stock_decrease_on_purchase_return',
      'trg_account_balance_increase',
      'trg_account_balance_decrease',
      'trg_update_transaction_payment_status',
    ];

    test('I5.1 exactly the seven effect triggers exist and each carries the '
        'is_synced guard', () async {
      final db = await openAtVersion(currentSchemaVersion);
      addTearDown(db.close);

      final rows = await db.rawQuery(
        "SELECT name, sql FROM sqlite_master WHERE type = 'trigger'",
      );
      final byName = {
        for (final r in rows) r['name'] as String: (r['sql'] as String?) ?? '',
      };

      for (final name in effectTriggers) {
        expect(byName.containsKey(name), isTrue,
            reason: 'missing effect trigger $name');
        expect(
          byName[name]!.contains('COALESCE(NEW.is_synced'),
          isTrue,
          reason: '$name is missing the COALESCE(NEW.is_synced) guard',
        );
      }
    });

    test('I5.3 sync-uuid stamp fills a NULL uuid on insert', () async {
      final db = await openAtVersion(currentSchemaVersion);
      addTearDown(db.close);
      await seedMinimal(db);

      // Insert into a synced table (parties) WITHOUT a uuid → trg_sync_uuid_*
      // must stamp one.
      final id = await db.insert('parties', {
        'business_id': 1,
        'name': 'No-UUID Party',
        'party_type': 'customer',
        // uuid intentionally omitted (NULL).
      });

      final uuid = await readStr(db, 'parties', 'uuid', id);
      expect(uuid, isNotNull);
      expect(uuid, isNotEmpty);
    });
  });
}
