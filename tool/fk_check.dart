import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Dry-run the v6 transactions-table rebuild against a COPY of the live DB so we
/// can iterate on the migration without rebuilding the whole Flutter app.
Future<void> main() async {
  const live = r'C:\Users\jaina\OneDrive\Documents\BusinessPro\business_pro.db';
  final copy = '${Directory.systemTemp.path}\\bp_migration_test.db';
  File(live).copySync(copy);
  print('testing on copy: $copy');

  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    copy,
    options: OpenDatabaseOptions(singleInstance: false),
  );
  await db.execute('PRAGMA foreign_keys = ON');

  try {
    // Turn FKs off at the CONNECTION level, before opening the transaction.
    // (Toggling inside a transaction is a no-op in SQLite.)
    await db.execute('PRAGMA foreign_keys = OFF');
    final fkBefore = await db.rawQuery('PRAGMA foreign_keys');
    print('foreign_keys before txn: $fkBefore');
    await db.transaction((txn) async {

      const txnTriggers = [
        'trg_account_balance_increase',
        'trg_account_balance_decrease',
        'trg_update_transaction_payment_status',
        'trg_stock_decrease_on_sale',
        'trg_stock_increase_on_sale_return',
        'trg_stock_increase_on_purchase',
        'trg_stock_decrease_on_purchase_return',
      ];
      for (final t in txnTriggers) {
        await txn.execute('DROP TRIGGER IF EXISTS $t');
      }
      await txn.execute('DROP TABLE IF EXISTS transactions_new');
      await txn.execute('''
        CREATE TABLE transactions_new (
          id                    INTEGER PRIMARY KEY AUTOINCREMENT,
          business_id           INTEGER NOT NULL REFERENCES businesses(id),
          party_id              INTEGER REFERENCES parties(id),
          account_id            INTEGER REFERENCES accounts(id),
          category_id           INTEGER REFERENCES expense_categories(id),
          transaction_type      TEXT    NOT NULL CHECK(transaction_type IN (
                                  'sale','sale_return','sale_order','estimate','delivery_challan',
                                  'purchase','purchase_return','purchase_order',
                                  'expense','other_income','payment_in','payment_out'
                                )),
          transaction_number    TEXT    NOT NULL,
          reference_number      TEXT,
          transaction_date      TEXT    NOT NULL,
          due_date              TEXT,
          subtotal              REAL    DEFAULT 0,
          discount_type         TEXT    DEFAULT 'none',
          discount_value        REAL    DEFAULT 0,
          discount_amount       REAL    DEFAULT 0,
          taxable_amount        REAL    DEFAULT 0,
          tax_amount            REAL    DEFAULT 0,
          cgst_amount           REAL    DEFAULT 0,
          sgst_amount           REAL    DEFAULT 0,
          igst_amount           REAL    DEFAULT 0,
          round_off             REAL    DEFAULT 0,
          total_amount          REAL    DEFAULT 0,
          paid_amount           REAL    DEFAULT 0,
          balance_amount        REAL    DEFAULT 0,
          payment_status        TEXT    DEFAULT 'unpaid',
          status                TEXT    DEFAULT 'active',
          shipping_address      TEXT,
          shipping_charges      REAL    DEFAULT 0,
          notes                 TEXT,
          terms_conditions      TEXT,
          linked_transaction_id INTEGER REFERENCES transactions(id),
          is_deleted            INTEGER DEFAULT 0,
          deleted_at            TEXT,
          created_at            TEXT    DEFAULT (datetime('now')),
          updated_at            TEXT    DEFAULT (datetime('now'))
        )
      ''');
      await txn.execute('''
        INSERT INTO transactions_new SELECT
          id, business_id, party_id, account_id, category_id, transaction_type,
          transaction_number, reference_number, transaction_date, due_date,
          subtotal, discount_type, discount_value, discount_amount, taxable_amount,
          tax_amount, cgst_amount, sgst_amount, igst_amount, round_off,
          total_amount, paid_amount, balance_amount, payment_status, status,
          shipping_address, shipping_charges, notes, terms_conditions,
          linked_transaction_id, is_deleted, deleted_at, created_at, updated_at
        FROM transactions
      ''');
      await txn.execute('DROP TABLE transactions');
      await txn.execute('ALTER TABLE transactions_new RENAME TO transactions');
      print('rebuild steps ok (pre-commit)');
      await txn.execute('CREATE INDEX idx_txn_business ON transactions(business_id)');
      await txn.execute('CREATE INDEX idx_txn_party    ON transactions(party_id)');
      await txn.execute('CREATE INDEX idx_txn_type     ON transactions(transaction_type)');
      await txn.execute('CREATE INDEX idx_txn_date     ON transactions(transaction_date)');
      await txn.execute('CREATE INDEX idx_txn_status   ON transactions(payment_status)');
      await txn.execute('CREATE INDEX idx_txn_number   ON transactions(transaction_number)');
    });
    print('COMMIT OK — migration succeeds');
    await db.execute('PRAGMA foreign_keys = ON');
    final fkc = await db.rawQuery('PRAGMA foreign_key_check');
    print('post-migration foreign_key_check: ${fkc.length} violation(s)');
    final rows = await db.rawQuery('SELECT id, transaction_type, linked_transaction_id FROM transactions ORDER BY id');
    print('transactions after migration: ${rows.length} rows');
    final types = await db.rawQuery("SELECT name FROM sqlite_master WHERE type='trigger' ORDER BY name");
    print('triggers present: ${types.map((r) => r['name']).join(', ')}');
  } catch (e) {
    print('FAILED: $e');
  }

  await db.close();
  File(copy).deleteSync();
}
