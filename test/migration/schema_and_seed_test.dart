// Schema-arrival, settings-seeding, and atomicity — all END-STATE assertions.
//
// HARNESS LIMITATION (respected here): _onCreate emits the v13 schema, so
// openAtVersion(N<13) yields the current schema *stamped* at N, not a genuine
// historical shape. So these tests never assert that a migration "added" X to an
// older shape (a transform). They assert only the END STATE after the DB is at
// v13 (built fresh, or upgraded across a gap). The one place a real upgrade gap
// matters — I2.4, non-destructive re-seed — opens below v11 so the v11 seed step
// actually re-runs, then proves a user value survived INSERT-OR-IGNORE.

import 'package:business_pro/core/database/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'migration_harness.dart';

void main() {
  setUpAll(initMigrationHarness);
  tearDown(disposeOpenedDatabases);

  Future<Database> v13Db() async {
    final db = await openAtVersion(currentSchemaVersion);
    addTearDown(db.close);
    return db;
  }

  Future<Set<String>> tableNames(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    return rows.map((r) => r['name'] as String).toSet();
  }

  Future<Set<String>> indexNames(Database db) async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    );
    return rows.map((r) => r['name'] as String).toSet();
  }

  Future<Set<String>> columnNames(Database db, String table) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.map((r) => r['name'] as String).toSet();
  }

  // ───────────────────────────────────────────────────────────────────────
  // GROUP 1 — SCHEMA PRESENT AT v13 (end state)
  // ───────────────────────────────────────────────────────────────────────
  group('Group 1 — schema present at v13', () {
    test('I1.2 all expected tables exist', () async {
      final db = await v13Db();
      final tables = await tableNames(db);
      const expected = [
        'businesses',
        'settings',
        'parties',
        'party_addresses',
        'item_categories',
        'units',
        'tax_rates',
        'items',
        'item_units',
        'item_price_history',
        'accounts',
        'payment_modes',
        'expense_categories',
        'transactions',
        'transaction_items',
        'payments',
        'sync_log',
        'devices',
        'sync_state',
        'employees',
        'attendance',
        'salary_payments',
        'employee_advances',
      ];
      for (final t in expected) {
        expect(tables, contains(t), reason: 'missing table $t');
      }
    });

    test('I1.3 key migration-added columns exist', () async {
      final db = await v13Db();

      expect(await columnNames(db, 'item_units'),
          containsAll(['conversion_factor', 'is_base_unit']));

      expect(await columnNames(db, 'transaction_items'),
          containsAll(['item_unit_id', 'conversion_factor', 'updated_at']));

      expect(
        await columnNames(db, 'transactions'),
        containsAll([
          'eway_bill_number',
          'place_of_supply',
          'transport_name',
          'vehicle_number',
          'delivery_date',
          'delivery_location',
          'shipping_city',
          'shipping_state',
          'shipping_pincode',
          'is_shipping_diff',
        ]),
      );

      expect(await columnNames(db, 'employees'),
          containsAll(['overtime_rate', 'advance_given', 'advance_paid']));

      expect(await columnNames(db, 'attendance'), contains('overtime_hours'));
    });

    test('I1.5 sync columns: uuid on synced tables; tracked tables get '
        'device_id + is_synced(default 0) + server_updated_at', () async {
      final db = await v13Db();

      // Every synced table carries uuid. (Mirrors DatabaseHelper.syncedTables.)
      const syncedTables = [
        'transactions',
        'transaction_items',
        'payments',
        'parties',
        'items',
        'item_units',
        'accounts',
        'expense_categories',
        'item_categories',
        // Employee module brought into sync at v14.
        'employees',
        'attendance',
        'salary_payments',
        'employee_advances',
      ];
      for (final t in syncedTables) {
        expect(await columnNames(db, t), contains('uuid'),
            reason: '$t should have uuid');
      }

      // Tracked tables additionally carry device_id / is_synced / server_updated_at.
      const tracked = [
        'transactions',
        'parties',
        'items',
        'payments',
        'accounts',
        'expense_categories',
        'item_categories',
        'item_units',
        'transaction_items',
        // Employee module (v14): each merged individually, so all are tracked.
        'employees',
        'attendance',
        'salary_payments',
        'employee_advances',
      ];
      for (final t in tracked) {
        expect(
          await columnNames(db, t),
          containsAll(['device_id', 'is_synced', 'server_updated_at']),
          reason: '$t should have the sync-tracking columns',
        );
      }

      // is_synced defaults to 0: a row inserted without it reads back 0.
      // (parties is a tracked table; supply uuid so the stamp trigger no-ops.)
      final id = await db.insert('parties', {
        'business_id': 1,
        'name': 'Default-Check Party',
        'party_type': 'customer',
        'uuid': 'default-check-uuid',
      });
      expect(await readNum(db, 'parties', 'is_synced', id), 0);
    });

    test('I1.6 spot-check indexes exist', () async {
      final db = await v13Db();
      final idx = await indexNames(db);
      const expected = [
        'idx_item_units_item',
        'idx_txn_business',
        'idx_txn_party',
        'idx_txn_type',
        'idx_txn_date',
        'idx_txn_status',
        'idx_txn_number',
        'idx_emp_business',
        'idx_att_employee',
        'idx_att_date',
        'idx_salary_emp',
        'idx_salary_month',
        'idx_advance_emp',
      ];
      for (final i in expected) {
        expect(idx, contains(i), reason: 'missing index $i');
      }
    });

    test('I1.4 end-state: a delivery_challan header inserts (v6 CHECK accepts it)',
        () async {
      final db = await v13Db();
      await seedMinimal(db);
      // The transaction_type CHECK constraint must include 'delivery_challan'
      // (added by the v6 table rebuild). A successful insert proves the
      // end-state CHECK accepts it; a stale CHECK would throw here.
      final id = await db.insert('transactions', {
        'business_id': 1,
        'transaction_type': 'delivery_challan',
        'transaction_number': 'DC-1',
        'transaction_date': '2026-01-01',
        'uuid': 'dc-uuid-1',
      });
      expect(id, greaterThan(0));
      expect(
        await readStr(db, 'transactions', 'transaction_type', id),
        'delivery_challan',
      );
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // GROUP 2 — SETTINGS SEEDING
  // ───────────────────────────────────────────────────────────────────────
  group('Group 2 — settings seeding', () {
    Future<String?> settingValue(Database db, String key) async {
      final rows = await db.query('settings',
          columns: ['value'],
          where: 'business_id = 1 AND key = ?',
          whereArgs: [key]);
      return rows.isEmpty ? null : rows.first['value'] as String?;
    }

    // The 45 keys seeded by preInsertPrintSettings (v11 step / _onCreate). The
    // two format keys (print_invoice_format/print_estimate_format) are seeded
    // separately and are NOT part of this 45 — see I2.1's count note.
    const printDefaults = <String>[
      'print_thermal_default',
      'print_paper_size',
      'print_copies',
      'print_extra_lines',
      'print_auto_cut',
      'print_cash_drawer',
      'print_text_styling',
      'print_regular_text_size',
      'print_page_size',
      'print_orientation',
      'print_repeat_header',
      'print_original_duplicate',
      'print_extra_top_space',
      'print_min_item_rows',
      'print_company_name',
      'print_company_name_size',
      'print_logo',
      'print_address',
      'print_email',
      'print_phone',
      'print_gstin',
      'print_show_sno',
      'print_show_hsn',
      'print_show_unit',
      'print_show_mrp',
      'print_show_description',
      'print_show_total_qty',
      'print_amount_decimal',
      'print_received_amount',
      'print_balance_amount',
      'print_party_balance',
      'print_tax_details',
      'print_amount_grouping',
      'print_amount_words_format',
      'print_you_saved',
      'print_description',
      'print_terms',
      'print_terms_text',
      'print_received_by',
      'print_delivered_by',
      'print_signature',
      'print_signature_text',
      'print_payment_mode',
      'print_page_numbers',
      'print_acknowledgement',
    ];

    test('I2.1 all 45 preInsert print_* keys exist (and the format keys bring '
        'the print_% total to 47)', () async {
      final db = await v13Db();

      for (final k in printDefaults) {
        expect(await settingValue(db, k), isNotNull, reason: 'missing $k');
      }

      // The 45 preInsert keys are a subset; LIKE 'print_%' also catches the two
      // format keys seeded elsewhere → 47 total on a fresh v13 DB.
      final countRows = await db.rawQuery(
        "SELECT COUNT(*) c FROM settings WHERE business_id = 1 AND key LIKE 'print\\_%' ESCAPE '\\'",
      );
      expect((countRows.first['c'] as int), 47);
      expect(printDefaults.length, 45);
    });

    test('I2.2 print_invoice_format=format1, print_estimate_format=format2',
        () async {
      final db = await v13Db();
      expect(await settingValue(db, 'print_invoice_format'), 'format1');
      expect(await settingValue(db, 'print_estimate_format'), 'format2');
    });

    test('I2.3 security keys are present and default to off/empty', () async {
      // FINDING (documented in report): security_pin_enabled / security_pin_hash
      // are seeded ONLY by _seedDefaultData (via _onCreate), not by any
      // oldVersion<N migration block. A freshly built DB (this harness always
      // routes through _onCreate) therefore has them — but a genuine real-world
      // upgrade from a pre-PIN version would NOT seed them. This test asserts the
      // fresh-install end-state; the missing-migration gap is a real finding the
      // app reads past safely via getSetting(defaultVal:).
      final db = await v13Db();
      expect(await settingValue(db, 'security_pin_enabled'), '0');
      expect(await settingValue(db, 'security_pin_hash'), '');
    });

    test('I2.4 non-destructive seed: a user-set print_* value survives the '
        'v11 INSERT-OR-IGNORE re-seed', () async {
      // Needs a real upgrade gap so the v11 seed step (oldVersion < 11) runs.
      // openAtVersion(10) builds the full v13 schema but stamps user_version=10;
      // _onCreate already pre-seeds the print_* keys, so we OVERWRITE one to a
      // non-default value, then upgrade. The v11 step re-runs
      // preInsertPrintSettings with ConflictAlgorithm.ignore, which must NOT
      // clobber our value.
      final db10 = await openAtVersion(10);

      // Sanity: we genuinely start below 11.
      expect(await readUserVersion(db10), 10);

      // Overwrite to a non-default (default is 'mm80').
      const userValue = 'mm58';
      final updated = await db10.update(
        'settings',
        {'value': userValue},
        where: 'business_id = 1 AND key = ?',
        whereArgs: ['print_paper_size'],
      );
      expect(updated, 1, reason: 'print_paper_size should already exist to update');

      final db13 = await upgradeToCurrent(db10);
      addTearDown(db13.close);

      // The upgrade ran v11→v13. user_version is now current.
      expect(await readUserVersion(db13), currentSchemaVersion);
      // The user value must have SURVIVED the re-seed.
      expect(await settingValue(db13, 'print_paper_size'), userValue);
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // GROUP 6 — ATOMICITY / IDEMPOTENCY
  //
  // IMPORTANT (real finding, see report): the upgrade BODY is idempotent only
  // for the v8→v13 range — those blocks use _addColumnIfMissing /
  // CREATE TABLE|TRIGGER IF NOT EXISTS / DROP IF EXISTS / ConflictAlgorithm.ignore.
  // The v2–v7 blocks use raw, unguarded `ALTER TABLE ... ADD COLUMN`,
  // `CREATE TABLE` and a transactions-table rebuild that were written to run
  // EXACTLY ONCE against a genuinely older schema. Replaying them against the
  // v13 schema this harness produces throws (e.g. "duplicate column name:
  // business_category"). That is correct production behaviour — sqflite never
  // replays an already-applied block — but it means a full 1→13 *replay* is not
  // a supportable idempotency test here. So Group 6 exercises the idempotent
  // tail (v8→13) across a real gap, which is genuinely re-runnable.
  // ───────────────────────────────────────────────────────────────────────
  group('Group 6 — atomicity / idempotency', () {
    test('I6.1 user_version == current after upgrading across a real gap (v8→16)',
        () async {
      final db8 = await openAtVersion(8);
      expect(await readUserVersion(db8), 8);
      final dbCur = await upgradeToCurrent(db8); // runs the real v9..v16 blocks
      addTearDown(dbCur.close);
      expect(await readUserVersion(dbCur), currentSchemaVersion);
      expect(currentSchemaVersion, 16);
      // v15/v16 add the free-text billing columns to transactions.
      final txnCols = await columnNames(dbCur, 'transactions');
      expect(txnCols, contains('billing_name'));
      expect(txnCols, contains('billing_gstin'));
      expect(txnCols, contains('billing_address'));
    });

    test('I6.2 re-running the idempotent upgrade tail (v8→13) is a no-op: no '
        'throw, schema unchanged', () async {
      // Reach v13 via a real upgrade gap so the v9..v13 blocks have actually run.
      final db8 = await openAtVersion(8);
      final db = await upgradeToCurrent(db8);
      addTearDown(db.close);

      final tablesBefore = await tableNames(db);
      final indexesBefore = await indexNames(db);
      final txnColsBefore = await columnNames(db, 'transactions');

      // Drive the REAL _onUpgrade (via the public test seam) across the same
      // idempotent range AGAIN on the already-migrated schema. It must not throw
      // (relies on IF NOT EXISTS / _addColumnIfMissing / ConflictAlgorithm.ignore).
      await expectLater(
        DatabaseHelper.onUpgradeForTest(db, 8, currentSchemaVersion),
        completes,
      );

      expect(await tableNames(db), equals(tablesBefore));
      expect(await indexNames(db), equals(indexesBefore));
      expect(await columnNames(db, 'transactions'), equals(txnColsBefore));
    });
  });

  // ───────────────────────────────────────────────────────────────────────
  // I3.1 — v6 foreign-key toggle, END STATE.
  //
  // The v6 migration rebuilds the transactions table with FK enforcement OFF
  // (set by _onConfigure for a pending sub-6 user_version) and restores it ON at
  // the end. We assert the observable PRODUCTION end-state: a current DB opened
  // through the REAL open path (real _onConfigure) ends with FKs ENABLED.
  //
  // We do NOT drive a genuine v5→v6 crossing here: per the A3.2 finding, this
  // harness's floor for upgrade gaps is v8 (the v2–v7 blocks use unguarded
  // ALTERs / a table rebuild and throw when replayed against the v13-stamped
  // schema _onCreate produces). Asserting the live OFF window mid-rebuild would
  // require an authentic pre-v6 snapshot to upgrade from — deferred, the same
  // limitation as the transform tests. We assert only the end-state and never
  // fake a mid-migration assertion.
  // ───────────────────────────────────────────────────────────────────────
  group('I3.1 — v6 FK toggle end-state', () {
    Future<int> foreignKeysPragma(Database db) async {
      final rows = await db.rawQuery('PRAGMA foreign_keys');
      return (rows.first.values.first as int?) ?? 0;
    }

    test('a fresh v13 DB (real _onConfigure) ends with foreign_keys ON',
        () async {
      final db = await v13Db();
      expect(await foreignKeysPragma(db), 1);
    });

    test('a DB upgraded across a real gap (v8→13) ends with foreign_keys ON',
        () async {
      final db8 = await openAtVersion(8);
      final db13 = await upgradeToCurrent(db8); // re-open runs real _onConfigure
      addTearDown(db13.close);
      expect(await readUserVersion(db13), currentSchemaVersion);
      expect(await foreignKeysPragma(db13), 1);
    });
  });
}
