// Migration test harness for BusinessPro.
//
// The whole point of this harness is to drive the REAL migration code
// (DatabaseHelper._onCreate / _onUpgrade / _onConfigure) against a
// test-controlled database opened at a chosen starting version — never a
// reimplementation of the migration SQL. It reaches the real callbacks via the
// public test-seam getters on DatabaseHelper (schemaVersion / onCreateForTest /
// onUpgradeForTest / onConfigureForTest), which are thin handles to the private
// statics and change no production behavior.
//
// Each opened DB is a fresh temp file (so WAL — which _onConfigure enables —
// behaves as it does in production) tracked for teardown. Call
// [disposeOpenedDatabases] in tearDown to close handles and delete the files.

import 'dart:io';

import 'package:business_pro/core/database/database_helper.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The current (target) schema version, sourced from the real app constant so
/// the harness never drifts from `DatabaseHelper._dbVersion`.
int get currentSchemaVersion => DatabaseHelper.schemaVersion;

/// Temp DB files opened by the harness, tracked for teardown.
final List<Directory> _openedDirs = <Directory>[];

/// Call once before any test (typically in `setUpAll`). Idempotent.
void initMigrationHarness() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// Opens a fresh database at [version], running the REAL migration code path:
///
///  * `version == currentSchemaVersion` → real `_onCreate` builds the full
///    current schema in one shot.
///  * `version < currentSchemaVersion` → real `_onCreate` builds the schema as
///    of that historical version's *creation* output, but note `_onCreate`
///    always emits the latest schema. To start at a genuine OLDER schema and
///    then migrate, open at [version] here, then pass the handle to
///    [upgradeToCurrent], which closes and re-opens at the current version so
///    sqflite invokes the real `_onUpgrade` across the gap.
///
/// Uses a fresh temp file per call (tracked for teardown) so WAL behaves as in
/// production and so the FK-toggle logic in `_onConfigure` runs for real.
Future<Database> openAtVersion(int version) async {
  final dir = await Directory.systemTemp.createTemp('bp_migration_test_');
  _openedDirs.add(dir);
  final path = p.join(dir.path, 'business_pro_test.db');

  return databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: DatabaseHelper.onCreateForTest,
      onUpgrade: DatabaseHelper.onUpgradeForTest,
      onConfigure: DatabaseHelper.onConfigureForTest,
    ),
  );
}

/// Re-opens [db]'s file at the current schema version, triggering the REAL
/// `_onUpgrade` across whatever gap exists between the file's stored
/// `user_version` and [currentSchemaVersion]. Returns the upgraded handle.
///
/// sqflite drives migrations off the file's persisted `user_version`, so the
/// only way to exercise `_onUpgrade` is to close a lower-version file and
/// re-open it at a higher version — which is exactly what this does.
Future<Database> upgradeToCurrent(Database db) async {
  final path = db.path;
  await db.close();
  return databaseFactory.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: currentSchemaVersion,
      onCreate: DatabaseHelper.onCreateForTest,
      onUpgrade: DatabaseHelper.onUpgradeForTest,
      onConfigure: DatabaseHelper.onConfigureForTest,
    ),
  );
}

/// The ids of the minimal fixture rows [seedMinimal] inserts, so tests can
/// attach transactions/payments/lines to known parents and assert against
/// known opening values.
class SeedRefs {
  SeedRefs({
    required this.businessId,
    required this.partyId,
    required this.accountId,
    required this.accountOpeningBalance,
    required this.itemId,
    required this.itemUnitId,
    required this.itemOpeningStock,
    required this.unitId,
  });

  final int businessId;
  final int partyId;
  final int accountId;

  /// The account's `current_balance` immediately after seeding — the baseline
  /// the account-balance triggers move from.
  final double accountOpeningBalance;

  final int itemId;
  final int itemUnitId;

  /// The item's `current_stock` immediately after seeding — the baseline the
  /// stock triggers move from.
  final double itemOpeningStock;

  final int unitId;
}

/// Seeds the minimum real rows the trigger tests need, on top of what the app's
/// own `_seedDefaultData` already created on a fresh v13 DB (business id=1, the
/// default units, a default "Cash" account, tax rates, etc.).
///
/// We add what the seed does NOT provide — one party, one item, and the item's
/// base `item_units` tier (so a line can carry a real `conversion_factor`) — and
/// we insert our OWN account and item with explicit, known opening values so the
/// trigger assertions move from a baseline this harness controls rather than
/// from a seed-internal default. All inserts are raw `db.insert` (no
/// repositories), so the tests exercise the schema + triggers, not app logic.
///
/// Every inserted row carries an explicit `uuid` so the `trg_sync_uuid_*` stamp
/// trigger does NOT fire on these seed inserts. (That stamp trigger issues an
/// AFTER-INSERT UPDATE, which on an `is_synced = 1` row would in turn trip the
/// `trg_sync_dirty_*` AFTER-UPDATE trigger and flip `is_synced` back to 0 —
/// irrelevant here since the seed rows aren't part of the local/synced
/// assertion, but we keep it deterministic regardless.)
Future<SeedRefs> seedMinimal(Database db) async {
  const businessId = 1; // the single-firm id the app hardcodes and seeds.

  final partyId = await db.insert('parties', {
    'business_id': businessId,
    'name': 'Test Party',
    'party_type': 'both',
    'uuid': 'seed-party-uuid',
  });

  const accountOpeningBalance = 1000.0;
  final accountId = await db.insert('accounts', {
    'business_id': businessId,
    'name': 'Test Account',
    'account_type': 'cash',
    'opening_balance': accountOpeningBalance,
    'current_balance': accountOpeningBalance,
    'uuid': 'seed-account-uuid',
  });

  const itemOpeningStock = 100.0;
  // The default "Piece" unit seeded by the app is id=1; use it for the base tier.
  const unitId = 1;
  final itemId = await db.insert('items', {
    'business_id': businessId,
    'name': 'Test Item',
    'unit_id': unitId,
    'item_type': 'product',
    'sale_price': 50.0,
    'purchase_price': 30.0,
    'opening_stock': itemOpeningStock,
    'current_stock': itemOpeningStock,
    'uuid': 'seed-item-uuid',
  });

  // Base unit tier (conversion_factor = 1) so a line item has a real factor to
  // snapshot, matching the multi-tier unit model.
  final itemUnitId = await db.insert('item_units', {
    'item_id': itemId,
    'unit_id': unitId,
    'unit_name': 'pcs',
    'conversion_factor': 1,
    'sale_price': 50.0,
    'purchase_price': 30.0,
    'is_base_unit': 1,
    'uuid': 'seed-itemunit-uuid',
  });

  return SeedRefs(
    businessId: businessId,
    partyId: partyId,
    accountId: accountId,
    accountOpeningBalance: accountOpeningBalance,
    itemId: itemId,
    itemUnitId: itemUnitId,
    itemOpeningStock: itemOpeningStock,
    unitId: unitId,
  );
}

/// Auto-incrementing suffix so each raw-inserted transaction gets a unique,
/// NOT-NULL `transaction_number` without the tests having to invent one.
int _txnSeq = 0;

/// Raw-inserts a transaction header of [type] and returns its id.
///
/// Sets every NOT-NULL column explicitly (business_id, transaction_type,
/// transaction_number, transaction_date) plus [totalAmount] (drives the
/// payment-status trigger) and an explicit [isSynced] so the local-vs-synced
/// distinction is unambiguous. An explicit `uuid` is supplied so the sync-uuid
/// stamp trigger does not fire (which would otherwise issue an AFTER-INSERT
/// UPDATE and, on a synced row, trip the dirty trigger).
Future<int> insertTransaction(
  Database db, {
  required String type,
  required int isSynced,
  int businessId = 1,
  int? partyId,
  double totalAmount = 0,
  double paidAmount = 0,
  double balanceAmount = 0,
  String paymentStatus = 'unpaid',
}) async {
  _txnSeq++;
  return db.insert('transactions', {
    'business_id': businessId,
    'party_id': partyId,
    'transaction_type': type,
    'transaction_number': 'T-$_txnSeq',
    'transaction_date': '2026-01-01',
    'total_amount': totalAmount,
    'paid_amount': paidAmount,
    'balance_amount': balanceAmount,
    'payment_status': paymentStatus,
    'is_synced': isSynced,
    'uuid': 'txn-uuid-$_txnSeq',
  });
}

/// Raw-inserts a [transaction_items] line under [transactionId] and returns its
/// id. The stock triggers read [itemId], [quantity], [conversionFactor], the
/// parent transaction's type, and [isSynced].
Future<int> insertTransactionItem(
  Database db, {
  required int transactionId,
  required int itemId,
  required double quantity,
  required int isSynced,
  double conversionFactor = 1,
  int? itemUnitId,
  String itemName = 'Test Item',
}) async {
  _txnSeq++;
  return db.insert('transaction_items', {
    'transaction_id': transactionId,
    'item_id': itemId,
    'item_unit_id': itemUnitId,
    'item_name': itemName,
    'quantity': quantity,
    'conversion_factor': conversionFactor,
    'unit_price': 0,
    'is_synced': isSynced,
    'uuid': 'txnitem-uuid-$_txnSeq',
  });
}

/// Raw-inserts a [payments] row against [transactionId] and returns its id. The
/// account-balance triggers read [accountId], [amount], the parent transaction's
/// type, and [isSynced]; the payment-status trigger reads [amount] and
/// [isSynced].
Future<int> insertPayment(
  Database db, {
  required int transactionId,
  required int accountId,
  required double amount,
  required int isSynced,
}) async {
  _txnSeq++;
  return db.insert('payments', {
    'transaction_id': transactionId,
    'account_id': accountId,
    'amount': amount,
    'payment_date': '2026-01-01',
    'is_synced': isSynced,
    'uuid': 'payment-uuid-$_txnSeq',
  });
}

/// Reads a single numeric column from a single-row lookup. Used by tests to read
/// back `current_stock`, `current_balance`, `paid_amount`, etc.
Future<double> readNum(
  Database db,
  String table,
  String column,
  int id,
) async {
  final rows = await db.query(table, columns: [column], where: 'id = ?', whereArgs: [id]);
  return (rows.first[column] as num).toDouble();
}

/// Reads a single text column from a single-row lookup.
Future<String?> readStr(
  Database db,
  String table,
  String column,
  int id,
) async {
  final rows = await db.query(table, columns: [column], where: 'id = ?', whereArgs: [id]);
  return rows.first[column] as String?;
}

/// Convenience: read the SQLite file's stored schema version.
Future<int> readUserVersion(Database db) async {
  final rows = await db.rawQuery('PRAGMA user_version');
  return (rows.first.values.first as int?) ?? 0;
}

/// Closes any open handles and deletes the temp dirs. Call in `tearDown`.
Future<void> disposeOpenedDatabases() async {
  for (final dir in _openedDirs) {
    try {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (_) {
      // Best-effort cleanup; a leaked temp dir must not fail a test.
    }
  }
  _openedDirs.clear();
}
