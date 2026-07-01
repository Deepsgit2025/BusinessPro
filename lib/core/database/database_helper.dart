import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DatabaseHelper {
  static const _dbName = 'business_pro.db';
  static const _dbVersion = 16;

  static Database? _db;

  static Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  /// Absolute path to the SQLite file (whether or not it's currently open).
  /// Used by the backup module to copy / restore the database.
  static Future<String> databasePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return join(dir.path, 'BusinessPro', _dbName);
  }

  /// Closes the open connection and drops the cached handle so the next
  /// [database] access re-opens from disk. Required before overwriting the file
  /// on restore — Windows holds a hard lock on the open .db otherwise.
  static Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  /// Re-opens the database after a restore (or any external file swap). The
  /// next [database] access would re-open lazily anyway; this forces it eagerly
  /// so callers can confirm the restored file opens cleanly.
  static Future<void> reopen() async {
    await close();
    _db = await _initDb();
  }

  static Future<Database> _initDb() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, 'BusinessPro', _dbName);
    await Directory(dirname(path)).create(recursive: true);

    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
      onConfigure: _onConfigure,
    );
  }

  // ─────────────────────────────────────────
  // TEST SEAM
  // ─────────────────────────────────────────
  // Public, read-only handles to the real migration callbacks + version so a
  // host migration test can drive the ACTUAL _onCreate/_onUpgrade/_onConfigure
  // against a test-controlled (temp/in-memory) database opened at any starting
  // version. Production code is unaffected — _initDb still wires the private
  // members directly and nothing here changes runtime behavior. These exist so
  // tests exercise the real migration code, never a copy of the SQL.
  static int get schemaVersion => _dbVersion;
  static Future<void> Function(Database, int) get onCreateForTest => _onCreate;
  static Future<void> Function(Database, int, int) get onUpgradeForTest =>
      _onUpgrade;
  static Future<void> Function(Database) get onConfigureForTest => _onConfigure;

  // ─────────────────────────────────────────
  // MIGRATIONS
  // ─────────────────────────────────────────

  static Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // v1 → v2: business profile additions (category, books beginning date,
    // show-on-card visibility flags for the shareable visiting card).
    if (oldVersion < 2) {
      const alters = [
        "ALTER TABLE businesses ADD COLUMN business_category TEXT",
        "ALTER TABLE businesses ADD COLUMN books_beginning_date TEXT",
        "ALTER TABLE businesses ADD COLUMN card_style TEXT DEFAULT 'classic'",
        "ALTER TABLE businesses ADD COLUMN show_gstin_on_card INTEGER DEFAULT 0",
        "ALTER TABLE businesses ADD COLUMN show_business_type_on_card INTEGER DEFAULT 0",
        "ALTER TABLE businesses ADD COLUMN show_business_category_on_card INTEGER DEFAULT 0",
      ];
      for (final sql in alters) {
        await db.execute(sql);
      }
      // Backfill books beginning date for existing installs.
      await db.update(
        'businesses',
        {'books_beginning_date': DateTime.now().toIso8601String()},
        where: 'books_beginning_date IS NULL',
      );
    }

    // v2 → v3: multi-tier unit pricing. Adds item_units, line-level unit
    // snapshot columns, and rebuilds stock triggers to multiply by the
    // conversion factor. Existing items each get one base-unit tier row.
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE item_units (
          id                  INTEGER PRIMARY KEY AUTOINCREMENT,
          item_id             INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
          unit_id             INTEGER NOT NULL REFERENCES units(id),
          unit_name           TEXT    NOT NULL,
          conversion_factor   REAL    NOT NULL DEFAULT 1,
          sale_price          REAL    NOT NULL DEFAULT 0,
          purchase_price      REAL    NOT NULL DEFAULT 0,
          mrp                 REAL    DEFAULT 0,
          is_base_unit        INTEGER DEFAULT 0,
          is_default_sale     INTEGER DEFAULT 0,
          is_default_purchase INTEGER DEFAULT 0,
          sort_order          INTEGER DEFAULT 0,
          is_active           INTEGER DEFAULT 1
        )
      ''');
      await db.execute('CREATE INDEX idx_item_units_item ON item_units(item_id)');

      await db.execute(
          'ALTER TABLE transaction_items ADD COLUMN item_unit_id INTEGER REFERENCES item_units(id)');
      await db.execute(
          'ALTER TABLE transaction_items ADD COLUMN conversion_factor REAL DEFAULT 1');

      // One base-unit tier per existing item, mirroring its current price/unit.
      // Items without a unit fall back to the business' first unit so the NOT
      // NULL unit_id constraint holds; unit_name snapshots its short name.
      await db.execute('''
        INSERT INTO item_units (
          item_id, unit_id, unit_name, conversion_factor,
          sale_price, purchase_price, mrp,
          is_base_unit, is_default_sale, is_default_purchase, sort_order, is_active
        )
        SELECT
          i.id,
          COALESCE(i.unit_id, (SELECT id FROM units WHERE business_id = i.business_id
                               ORDER BY id LIMIT 1)),
          COALESCE((SELECT short_name FROM units WHERE id = i.unit_id), 'unit'),
          1,
          i.sale_price, i.purchase_price, i.mrp,
          1, 1, 1, 0, 1
        FROM items i
      ''');

      // Rebuild stock triggers to use the snapshotted conversion factor.
      const triggers = [
        'trg_stock_decrease_on_sale',
        'trg_stock_increase_on_sale_return',
        'trg_stock_increase_on_purchase',
        'trg_stock_decrease_on_purchase_return',
      ];
      for (final t in triggers) {
        await db.execute('DROP TRIGGER IF EXISTS $t');
      }
      await _createStockTriggers(db);
    }

    // v3 → v4: per-business toggles controlling whether bank details and the
    // UPI QR code are printed on invoices. Both default ON to match the prior
    // implicit behaviour (details always shown when present).
    if (oldVersion < 4) {
      const alters = [
        "ALTER TABLE businesses ADD COLUMN print_bank_on_invoice INTEGER DEFAULT 1",
        "ALTER TABLE businesses ADD COLUMN print_upi_qr_on_invoice INTEGER DEFAULT 1",
      ];
      for (final sql in alters) {
        await db.execute(sql);
      }
    }

    // v4 → v5: receipt counter for Payment-In numbering (RCPT-0001 …).
    if (oldVersion < 5) {
      await db.execute(
          'ALTER TABLE businesses ADD COLUMN receipt_counter INTEGER DEFAULT 1');
    }

    // v5 → v6: add 'delivery_challan' to the transaction_type CHECK constraint.
    // SQLite can't alter a CHECK in place, so rebuild the table: create the new
    // table, copy rows, drop the old one, rename, and recreate its indexes.
    // The transactions table self-references (linked_transaction_id) and has
    // child rows in transaction_items/payments, so the drop/rename requires
    // foreign-key enforcement to be OFF — which _onConfigure has already set for
    // a pending v6 upgrade (it can't be toggled here inside sqflite's migration
    // transaction). We restore it at the end of this block.
    if (oldVersion < 6) {
      // Seven triggers reference the transactions table in their bodies (the
      // payment/account-balance triggers on `payments` and the four stock
      // triggers on `transaction_items`). Dropping/renaming transactions while
      // they exist makes SQLite fail validating them ("no such table"), so drop
      // them first and recreate them from the canonical helpers after the swap.
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
        await db.execute('DROP TRIGGER IF EXISTS $t');
      }
      // Drop any leftover temp table from a previously failed attempt so the
      // rebuild is safe to re-run.
      await db.execute('DROP TABLE IF EXISTS transactions_new');
      await db.execute('''
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
          discount_type         TEXT    DEFAULT 'none'
                                    CHECK(discount_type IN ('none','percent','flat')),
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
          payment_status        TEXT    DEFAULT 'unpaid'
                                    CHECK(payment_status IN ('paid','unpaid','partial')),
          status                TEXT    DEFAULT 'active'
                                    CHECK(status IN ('active','cancelled','draft','converted')),
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
      await db.execute('''
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
      await db.execute('DROP TABLE transactions');
      await db.execute('ALTER TABLE transactions_new RENAME TO transactions');
      await db.execute('CREATE INDEX idx_txn_business ON transactions(business_id)');
      await db.execute('CREATE INDEX idx_txn_party    ON transactions(party_id)');
      await db.execute('CREATE INDEX idx_txn_type     ON transactions(transaction_type)');
      await db.execute('CREATE INDEX idx_txn_date     ON transactions(transaction_date)');
      await db.execute('CREATE INDEX idx_txn_status   ON transactions(payment_status)');
      await db.execute('CREATE INDEX idx_txn_number   ON transactions(transaction_number)');
      // Recreate the triggers dropped above, now that transactions exists again.
      await _createTriggers(db);
      // Restore foreign-key enforcement that _onConfigure left OFF for the
      // rebuild. Safe to set here: it takes effect after this migration
      // transaction commits.
      await db.execute('PRAGMA foreign_keys = ON');
    }

    // v6 → v7: employee module. Two tables — `employees` (name + daily pay)
    // and `attendance` (one row per employee per day, present/half/absent).
    if (oldVersion < 7) {
      await _createEmployeeTables(db);
    }

    // v7 → v8: Phase 5 Google Drive sync. Adds row-level sync metadata (uuid +
    // device_id + is_synced + server_updated_at) to every synced table, the
    // sync_log / devices / sync_state tables, INSERT triggers that stamp uuid +
    // device_id automatically (so no repository code changes), and a one-time
    // UUID backfill for existing rows.
    if (oldVersion < 8) {
      await _createSyncColumns(db);
      await _createSyncTables(db);
      await _createSyncTriggers(db);
      await _backfillSyncUuids(db);
    }

    // v8 → v9: change detection switched from a timestamp high-water mark (which
    // skewed across the UTC/local timestamp formats in this DB and silently
    // skipped rows) to the is_synced flag. These AFTER UPDATE triggers reset
    // is_synced = 0 whenever the app edits a synced row, so edits re-upload.
    // Existing rows are left as-is (already-synced ones stay synced).
    if (oldVersion < 9) {
      await _createSyncUpdateTriggers(db);
    }

    // v9 → v10: guard the stock + payment effect-triggers so they DON'T fire on
    // sync-merged rows (which already carry their effects). Without this, every
    // synced bill double-applied stock and account balance and corrupted payment
    // status. Drop and recreate all seven with the new is_synced guard.
    if (oldVersion < 10) {
      const guardedTriggers = [
        'trg_stock_decrease_on_sale',
        'trg_stock_increase_on_sale_return',
        'trg_stock_increase_on_purchase',
        'trg_stock_decrease_on_purchase_return',
        'trg_account_balance_increase',
        'trg_account_balance_decrease',
        'trg_update_transaction_payment_status',
      ];
      for (final t in guardedTriggers) {
        await db.execute('DROP TRIGGER IF EXISTS $t');
      }
      await _createStockTriggers(db);
      await _createPaymentTriggers(db);
    }

    // v10 → v11: Printer phase. Seed the 45 print_* keys for existing
    // installs. Uses ConflictAlgorithm.ignore so any key the user has already
    // set (impossible on this exact upgrade, but safe under re-runs) is never
    // overwritten. Gives the future Settings phase its keys with no migration.
    if (oldVersion < 11) {
      await preInsertPrintSettings(db);
    }

    // v11 → v12: Invoice Format 1 — transport / delivery + shipping-address
    // fields on the transactions row, and the print_invoice_format setting.
    // `shipping_address` already exists (since v1), so only the new columns are
    // added; each ALTER is guarded so the migration is safe to re-run.
    if (oldVersion < 12) {
      await _createTransportColumns(db);
      await db.insert(
        'settings',
        {'business_id': 1, 'key': 'print_invoice_format', 'value': 'format1'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      await db.insert(
        'settings',
        {'business_id': 1, 'key': 'print_estimate_format', 'value': 'format2'},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    }

    // v12 → v13: employee module — overtime + advances + payroll history.
    // Adds overtime_rate / advance_given / advance_paid to employees,
    // overtime_hours to attendance (overtime rides on a logged day rather than
    // being a 4th mutually-exclusive status, so the existing present/half/absent
    // CHECK and calendar are untouched), and the salary_payments /
    // employee_advances tables.
    if (oldVersion < 13) {
      await _createEmployeeExtensions(db);
    }

    // v13 → v14: bring the employee module into Phase-5 sync. The employee
    // tables (employees / attendance / salary_payments / employee_advances)
    // were never registered as synced tables, so they had no uuid identity,
    // no device_id/is_synced tracking, and no stamping/dirty triggers — and
    // the engine neither exported nor merged them. They are now in
    // [syncedTables] + the `tracked` list, so re-running the sync-schema steps
    // (all of which loop those lists and are column-aware + idempotent) adds
    // everything to the four tables in place:
    //   - uuid on all four; device_id/is_synced/server_updated_at on all four;
    //   - the AFTER INSERT uuid/device_id stamp + AFTER UPDATE dirty triggers;
    //   - a one-time uuid backfill onto existing employee/attendance/etc rows.
    // It is safe to re-run for the already-synced tables (ALTERs are guarded,
    // triggers use IF NOT EXISTS, the backfill only fills NULL uuids).
    if (oldVersion < 14) {
      // The three child tables track edits by created_at only; give them an
      // updated_at so an edited attendance/salary/advance row carries a fresh
      // timestamp the latest-wins merge can compare. (employees already has
      // updated_at from v7.)
      await _addColumnIfMissing(db, 'attendance', 'updated_at', 'TEXT');
      await _addColumnIfMissing(db, 'salary_payments', 'updated_at', 'TEXT');
      await _addColumnIfMissing(db, 'employee_advances', 'updated_at', 'TEXT');
      await _createSyncColumns(db);
      await _createSyncTriggers(db);
      await _createSyncUpdateTriggers(db);
      await _backfillSyncUuids(db);
    }

    // v14 → v15: free-text billing name on a transaction. Lets a one-off
    // customer/supplier be named directly on the document without creating a
    // party record. Null for existing rows (they keep using party_id).
    if (oldVersion < 15) {
      await _addColumnIfMissing(db, 'transactions', 'billing_name', 'TEXT');
    }

    // v15 → v16: free-text billing GSTIN + address on a transaction, alongside
    // the v15 billing_name. Lets a one-off customer/supplier carry its own
    // GSTIN/address on the document without a party record. Null for existing
    // rows (party-linked docs read these off the party).
    if (oldVersion < 16) {
      await _addColumnIfMissing(db, 'transactions', 'billing_gstin', 'TEXT');
      await _addColumnIfMissing(db, 'transactions', 'billing_address', 'TEXT');
    }
  }

  static Future<void> _onConfigure(Database db) async {
    // The v6 migration rebuilds the transactions table (drop + rename), which
    // SQLite only allows with foreign-key enforcement OFF. That pragma is a
    // no-op once a transaction is open, and sqflite wraps onUpgrade in a
    // transaction — so we must clear it here, before the upgrade runs. When an
    // upgrade to v6 is pending we leave FKs OFF; _onUpgrade turns them back ON
    // as its final step. (Deferring instead of disabling fails: the rebuild
    // increments SQLite's deferred-constraint counter and COMMIT then throws 787
    // even though foreign_key_check reports the data is clean.)
    final result = await db.rawQuery('PRAGMA user_version');
    final pending = (result.first.values.first as int?) ?? 0;
    if (pending == 0 || pending >= 6) {
      // Fresh DB (onCreate) or already migrated: normal enforcement.
      await db.execute('PRAGMA foreign_keys = ON');
    } else {
      await db.execute('PRAGMA foreign_keys = OFF');
    }
    // Using rawQuery instead of execute because WAL returns a result set,
    // which some Android versions/sqflite versions require.
    await db.rawQuery('PRAGMA journal_mode = WAL');
  }

  static Future<void> _onCreate(Database db, int version) async {
    await _createTables(db);
    await _createTransportColumns(db);
    await _createEmployeeExtensions(db);
    await _createIndexes(db);
    await _createTriggers(db);
    await _seedDefaultData(db);
    // Phase 5 sync schema. Reuse the exact same steps as the v8 upgrade so a
    // fresh DB and an upgraded DB end up identical: add the per-row sync columns,
    // the sync-support tables, the uuid/device_id stamping triggers, then backfill
    // UUIDs onto the rows seeded above (which predate the triggers).
    await _createSyncColumns(db);
    await _createSyncTables(db);
    await _createSyncTriggers(db);
    await _createSyncUpdateTriggers(db);
    await _backfillSyncUuids(db);
  }

  // ─────────────────────────────────────────
  // TABLE CREATION
  // ─────────────────────────────────────────

  static Future<void> _createTables(Database db) async {
    await db.execute('''
      CREATE TABLE businesses (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        name                TEXT    NOT NULL,
        legal_name          TEXT,
        business_type       TEXT,
        business_category   TEXT,
        gstin               TEXT,
        pan_number          TEXT,
        phone               TEXT,
        alternate_phone     TEXT,
        email               TEXT,
        website             TEXT,
        address_line1       TEXT,
        address_line2       TEXT,
        city                TEXT,
        state               TEXT,
        pincode             TEXT,
        country             TEXT    DEFAULT 'India',
        currency_code       TEXT    DEFAULT 'INR',
        currency_symbol     TEXT    DEFAULT '₹',
        financial_year_start TEXT   DEFAULT '04-01',
        books_beginning_date TEXT,
        logo_path           TEXT,
        signature_path      TEXT,
        card_style          TEXT    DEFAULT 'classic',
        show_gstin_on_card             INTEGER DEFAULT 0,
        show_business_type_on_card     INTEGER DEFAULT 0,
        show_business_category_on_card INTEGER DEFAULT 0,
        bank_name           TEXT,
        bank_account_no     TEXT,
        bank_ifsc           TEXT,
        bank_branch         TEXT,
        upi_id              TEXT,
        print_bank_on_invoice    INTEGER DEFAULT 1,
        print_upi_qr_on_invoice  INTEGER DEFAULT 1,
        invoice_prefix      TEXT    DEFAULT 'INV',
        invoice_counter     INTEGER DEFAULT 1,
        purchase_prefix     TEXT    DEFAULT 'PUR',
        purchase_counter    INTEGER DEFAULT 1,
        receipt_counter     INTEGER DEFAULT 1,
        is_active           INTEGER DEFAULT 1,
        created_at          TEXT    DEFAULT (datetime('now')),
        updated_at          TEXT    DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE settings (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id  INTEGER NOT NULL REFERENCES businesses(id),
        key          TEXT    NOT NULL,
        value        TEXT,
        UNIQUE(business_id, key)
      )
    ''');

    await db.execute('''
      CREATE TABLE parties (
        id                    INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id           INTEGER NOT NULL REFERENCES businesses(id),
        name                  TEXT    NOT NULL,
        party_type            TEXT    NOT NULL CHECK(party_type IN ('customer','supplier','both')),
        phone                 TEXT,
        alternate_phone       TEXT,
        email                 TEXT,
        gstin                 TEXT,
        pan_number            TEXT,
        credit_limit          REAL    DEFAULT 0,
        credit_days           INTEGER DEFAULT 0,
        opening_balance       REAL    DEFAULT 0,
        opening_balance_type  TEXT    DEFAULT 'debit'
                                  CHECK(opening_balance_type IN ('debit','credit')),
        billing_address       TEXT,
        billing_city          TEXT,
        billing_state         TEXT,
        billing_pincode       TEXT,
        notes                 TEXT,
        additional_field1     TEXT,
        additional_field2     TEXT,
        additional_field3     TEXT,
        additional_date       TEXT,
        is_active             INTEGER DEFAULT 1,
        created_at            TEXT    DEFAULT (datetime('now')),
        updated_at            TEXT    DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE party_addresses (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        party_id    INTEGER NOT NULL REFERENCES parties(id) ON DELETE CASCADE,
        label       TEXT    DEFAULT 'Shipping',
        address     TEXT,
        city        TEXT,
        state       TEXT,
        pincode     TEXT,
        is_default  INTEGER DEFAULT 0,
        created_at  TEXT    DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE item_categories (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id INTEGER NOT NULL REFERENCES businesses(id),
        name        TEXT    NOT NULL,
        description TEXT,
        is_active   INTEGER DEFAULT 1,
        created_at  TEXT    DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE units (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id INTEGER NOT NULL REFERENCES businesses(id),
        name        TEXT    NOT NULL,
        short_name  TEXT    NOT NULL,
        is_active   INTEGER DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE tax_rates (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id INTEGER NOT NULL REFERENCES businesses(id),
        name        TEXT    NOT NULL,
        rate        REAL    NOT NULL DEFAULT 0,
        cgst_rate   REAL    DEFAULT 0,
        sgst_rate   REAL    DEFAULT 0,
        igst_rate   REAL    DEFAULT 0,
        is_active   INTEGER DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE items (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id         INTEGER NOT NULL REFERENCES businesses(id),
        category_id         INTEGER REFERENCES item_categories(id),
        unit_id             INTEGER REFERENCES units(id),
        tax_rate_id         INTEGER REFERENCES tax_rates(id),
        name                TEXT    NOT NULL,
        description         TEXT,
        sku                 TEXT,
        barcode             TEXT,
        hsn_code            TEXT,
        item_type           TEXT    DEFAULT 'product'
                                CHECK(item_type IN ('product','service')),
        sale_price          REAL    DEFAULT 0,
        purchase_price      REAL    DEFAULT 0,
        mrp                 REAL    DEFAULT 0,
        wholesale_price     REAL    DEFAULT 0,
        opening_stock       REAL    DEFAULT 0,
        current_stock       REAL    DEFAULT 0,
        min_stock_level     REAL    DEFAULT 0,
        stock_value_method  TEXT    DEFAULT 'fifo'
                                CHECK(stock_value_method IN ('fifo','avg','fixed')),
        discount_type       TEXT    DEFAULT 'none'
                                CHECK(discount_type IN ('none','percent','flat')),
        discount_value      REAL    DEFAULT 0,
        tax_inclusive       INTEGER DEFAULT 0,
        is_active           INTEGER DEFAULT 1,
        created_at          TEXT    DEFAULT (datetime('now')),
        updated_at          TEXT    DEFAULT (datetime('now'))
      )
    ''');

    // Multi-tier unit pricing. Each item has one or more selling units that map
    // back to the base (stock-tracking) unit via conversion_factor. The base
    // unit row (is_base_unit = 1, conversion_factor = 1) mirrors the legacy
    // price/unit columns kept on the items row for backward compatibility.
    await db.execute('''
      CREATE TABLE item_units (
        id                  INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id             INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        unit_id             INTEGER NOT NULL REFERENCES units(id),
        unit_name           TEXT    NOT NULL,
        conversion_factor   REAL    NOT NULL DEFAULT 1,
        sale_price          REAL    NOT NULL DEFAULT 0,
        purchase_price      REAL    NOT NULL DEFAULT 0,
        mrp                 REAL    DEFAULT 0,
        is_base_unit        INTEGER DEFAULT 0,
        is_default_sale     INTEGER DEFAULT 0,
        is_default_purchase INTEGER DEFAULT 0,
        sort_order          INTEGER DEFAULT 0,
        is_active           INTEGER DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE item_price_history (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        item_id     INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE,
        price_type  TEXT    NOT NULL CHECK(price_type IN ('sale','purchase','mrp')),
        old_price   REAL,
        new_price   REAL,
        changed_at  TEXT    DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE accounts (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id     INTEGER NOT NULL REFERENCES businesses(id),
        name            TEXT    NOT NULL,
        account_type    TEXT    NOT NULL
                            CHECK(account_type IN ('cash','bank','wallet')),
        bank_name       TEXT,
        account_number  TEXT,
        ifsc_code       TEXT,
        opening_balance REAL    DEFAULT 0,
        current_balance REAL    DEFAULT 0,
        is_default      INTEGER DEFAULT 0,
        is_active       INTEGER DEFAULT 1,
        created_at      TEXT    DEFAULT (datetime('now')),
        updated_at      TEXT    DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE payment_modes (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id INTEGER NOT NULL REFERENCES businesses(id),
        name        TEXT    NOT NULL,
        type        TEXT    DEFAULT 'digital'
                        CHECK(type IN ('cash','digital','credit')),
        is_active   INTEGER DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE expense_categories (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id  INTEGER NOT NULL REFERENCES businesses(id),
        name         TEXT    NOT NULL,
        category_for TEXT    DEFAULT 'expense'
                         CHECK(category_for IN ('expense','income','both')),
        is_active    INTEGER DEFAULT 1
      )
    ''');

    await db.execute('''
      CREATE TABLE transactions (
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
        billing_name          TEXT,
        billing_gstin         TEXT,
        billing_address       TEXT,
        transaction_date      TEXT    NOT NULL,
        due_date              TEXT,
        subtotal              REAL    DEFAULT 0,
        discount_type         TEXT    DEFAULT 'none'
                                  CHECK(discount_type IN ('none','percent','flat')),
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
        payment_status        TEXT    DEFAULT 'unpaid'
                                  CHECK(payment_status IN ('paid','unpaid','partial')),
        status                TEXT    DEFAULT 'active'
                                  CHECK(status IN ('active','cancelled','draft','converted')),
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

    await db.execute('''
      CREATE TABLE transaction_items (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id  INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
        item_id         INTEGER REFERENCES items(id),
        item_unit_id    INTEGER REFERENCES item_units(id),
        item_name       TEXT    NOT NULL,
        item_hsn        TEXT,
        unit_name       TEXT,
        quantity        REAL    NOT NULL DEFAULT 1,
        conversion_factor REAL  DEFAULT 1,
        unit_price      REAL    NOT NULL DEFAULT 0,
        mrp             REAL    DEFAULT 0,
        discount_type   TEXT    DEFAULT 'none'
                            CHECK(discount_type IN ('none','percent','flat')),
        discount_value  REAL    DEFAULT 0,
        discount_amount REAL    DEFAULT 0,
        taxable_amount  REAL    DEFAULT 0,
        tax_rate_id     INTEGER REFERENCES tax_rates(id),
        tax_rate        REAL    DEFAULT 0,
        tax_amount      REAL    DEFAULT 0,
        cgst_amount     REAL    DEFAULT 0,
        sgst_amount     REAL    DEFAULT 0,
        igst_amount     REAL    DEFAULT 0,
        tax_inclusive   INTEGER DEFAULT 0,
        total_amount    REAL    DEFAULT 0,
        sort_order      INTEGER DEFAULT 0,
        notes           TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE payments (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id   INTEGER NOT NULL REFERENCES transactions(id) ON DELETE CASCADE,
        account_id       INTEGER REFERENCES accounts(id),
        payment_mode_id  INTEGER REFERENCES payment_modes(id),
        amount           REAL    NOT NULL,
        payment_date     TEXT    NOT NULL DEFAULT (date('now')),
        reference_number TEXT,
        notes            TEXT,
        created_at       TEXT    DEFAULT (datetime('now'))
      )
    ''');

    await _createEmployeeTables(db);
  }

  /// Employee module tables (v7). Extracted so both onCreate and the v7
  /// migration share one definition.
  ///
  /// `daily_pay` is the wage for one full present day. Attendance is logged at
  /// most once per employee per day (UNIQUE on employee_id + date); status is
  /// 'present', 'half', or 'absent'. `day_value` snapshots the pay weight for
  /// that day (1.0 / 0.5 / 0.0) so historical payroll is unaffected if the
  /// half-day rule ever changes.
  static Future<void> _createEmployeeTables(Database db) async {
    await db.execute('''
      CREATE TABLE employees (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id INTEGER NOT NULL REFERENCES businesses(id),
        name        TEXT    NOT NULL,
        phone       TEXT,
        role        TEXT,
        daily_pay   REAL    NOT NULL DEFAULT 0,
        join_date   TEXT,
        notes       TEXT,
        is_active   INTEGER DEFAULT 1,
        created_at  TEXT    DEFAULT (datetime('now')),
        updated_at  TEXT    DEFAULT (datetime('now'))
      )
    ''');

    await db.execute('''
      CREATE TABLE attendance (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        employee_id INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
        date        TEXT    NOT NULL,
        status      TEXT    NOT NULL DEFAULT 'present'
                        CHECK(status IN ('present','half','absent')),
        day_value   REAL    NOT NULL DEFAULT 1,
        note        TEXT,
        created_at  TEXT    DEFAULT (datetime('now')),
        UNIQUE(employee_id, date)
      )
    ''');
    await db.execute('CREATE INDEX idx_emp_business ON employees(business_id)');
    await db.execute('CREATE INDEX idx_att_employee ON attendance(employee_id)');
    await db.execute('CREATE INDEX idx_att_date     ON attendance(date)');
  }

  /// Employee overtime + advances + payroll history (v13). Extracted so both
  /// onCreate and the v13 migration share one definition. Column ALTERs are
  /// guarded via [_addColumnIfMissing]; the CREATE TABLEs use IF NOT EXISTS — so
  /// the whole method is safe on both fresh and upgraded DBs.
  ///
  /// Overtime rides on an existing attendance row as `overtime_hours` (it is
  /// not a 4th status), so the present/half/absent CHECK constraint and the
  /// existing calendar/roll-up keep working. `advance_given` / `advance_paid`
  /// accumulate the running advance; outstanding = given − paid.
  static Future<void> _createEmployeeExtensions(Database db) async {
    await _addColumnIfMissing(db, 'employees', 'overtime_rate', 'REAL DEFAULT 0');
    await _addColumnIfMissing(db, 'employees', 'advance_given', 'REAL DEFAULT 0');
    await _addColumnIfMissing(db, 'employees', 'advance_paid', 'REAL DEFAULT 0');
    await _addColumnIfMissing(
        db, 'attendance', 'overtime_hours', 'REAL DEFAULT 0');

    // updated_at on attendance (it otherwise tracks by created_at only). The
    // latest-wins sync merge (v14) compares this so an edited day re-syncs.
    // attendance predates v13, so it needs a guarded ALTER; salary_payments /
    // employee_advances carry updated_at directly in their CREATE TABLE below.
    // employees already has updated_at from its v7 definition.
    await _addColumnIfMissing(db, 'attendance', 'updated_at', 'TEXT');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS salary_payments (
        id               INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id      INTEGER NOT NULL REFERENCES businesses(id),
        employee_id      INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
        payment_month    TEXT    NOT NULL,
        salary_earned    REAL    NOT NULL DEFAULT 0,
        cash_paid        REAL    DEFAULT 0,
        advance_credited REAL    DEFAULT 0,
        remaining        REAL    DEFAULT 0,
        full_days        INTEGER DEFAULT 0,
        half_days        INTEGER DEFAULT 0,
        absent_days      INTEGER DEFAULT 0,
        overtime_hours   REAL    DEFAULT 0,
        overtime_amount  REAL    DEFAULT 0,
        notes            TEXT,
        payment_date     TEXT    DEFAULT (date('now')),
        created_at       TEXT    DEFAULT (datetime('now')),
        updated_at       TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS employee_advances (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id  INTEGER NOT NULL REFERENCES businesses(id),
        employee_id  INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
        amount       REAL    NOT NULL,
        type         TEXT    NOT NULL CHECK(type IN ('given','credited')),
        notes        TEXT,
        advance_date TEXT    DEFAULT (date('now')),
        created_at   TEXT    DEFAULT (datetime('now')),
        updated_at   TEXT
      )
    ''');

    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_salary_emp   ON salary_payments(employee_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_salary_month ON salary_payments(payment_month)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_advance_emp  ON employee_advances(employee_id)');
  }

  /// Invoice Format 1 transport / delivery + shipping columns on transactions
  /// (v12). Extracted so both onCreate and the v12 migration share one
  /// definition. `shipping_address` predates this (added in v1) so it's omitted
  /// here. Each ALTER is guarded via [_addColumnIfMissing] so it's safe on both
  /// fresh and upgraded DBs.
  static Future<void> _createTransportColumns(Database db) async {
    const cols = <String, String>{
      'eway_bill_number': 'TEXT',
      'place_of_supply': 'TEXT',
      'transport_name': 'TEXT',
      'vehicle_number': 'TEXT',
      'delivery_date': 'TEXT',
      'delivery_location': 'TEXT',
      'shipping_city': 'TEXT',
      'shipping_state': 'TEXT',
      'shipping_pincode': 'TEXT',
      'is_shipping_diff': 'INTEGER DEFAULT 0',
    };
    for (final e in cols.entries) {
      await _addColumnIfMissing(db, 'transactions', e.key, e.value);
    }
  }

  // ─────────────────────────────────────────
  // PHASE 5 — SYNC SCHEMA
  // ─────────────────────────────────────────

  /// Tables that participate in two-way sync. The UI joins/inserts these by
  /// integer id locally, but across devices the `uuid` column is the identity.
  static const syncedTables = <String>[
    'transactions',
    'transaction_items',
    'payments',
    'parties',
    'items',
    'item_units',
    'accounts',
    'expense_categories',
    'item_categories',
    // Employee module (added v14). employees is the parent; attendance,
    // salary_payments and employee_advances cascade off it (employee_id FK).
    'employees',
    'attendance',
    'salary_payments',
    'employee_advances',
  ];

  /// Per-row sync metadata. Every synced table gets a `uuid` (the cross-device
  /// identity). The "main" tables additionally get device_id / is_synced /
  /// server_updated_at so the engine can attribute and track them; child tables
  /// (transaction_items) and master lists carry uuid alone and ride their
  /// parent's timestamps. Adding a column that already exists throws, so each
  /// ALTER is guarded — this lets the method run on both fresh and upgraded DBs.
  static Future<void> _createSyncColumns(Database db) async {
    // uuid on every synced table.
    for (final t in syncedTables) {
      await _addColumnIfMissing(db, t, 'uuid', 'TEXT');
    }
    // Sync-tracking columns on the tables the engine tracks individually.
    const tracked = [
      'transactions',
      'parties',
      'items',
      'payments',
      'accounts',
      'expense_categories',
      'item_categories',
      'item_units',
      // Employee module (v14): each is merged individually with its own
      // latest-wins timestamp, so each gets full device_id/is_synced tracking.
      'employees',
      'attendance',
      'salary_payments',
      'employee_advances',
    ];
    for (final t in tracked) {
      await _addColumnIfMissing(db, t, 'device_id', 'TEXT');
      await _addColumnIfMissing(db, t, 'is_synced', 'INTEGER DEFAULT 0');
      await _addColumnIfMissing(db, t, 'server_updated_at', 'TEXT');
    }
    // transaction_items has no updated_at of its own; give it one so edited
    // lines carry a fresh timestamp the merge can compare.
    await _addColumnIfMissing(db, 'transaction_items', 'device_id', 'TEXT');
    await _addColumnIfMissing(db, 'transaction_items', 'is_synced', 'INTEGER DEFAULT 0');
    await _addColumnIfMissing(db, 'transaction_items', 'updated_at', 'TEXT');
    await _addColumnIfMissing(db, 'transaction_items', 'server_updated_at', 'TEXT');
  }

  /// Adds [column] to [table] only if it isn't already present. PRAGMA
  /// table_info is cheap and avoids relying on a thrown "duplicate column" error.
  static Future<void> _addColumnIfMissing(
      Database db, String table, String column, String type) async {
    final cols = await db.rawQuery('PRAGMA table_info($table)');
    final exists = cols.any((c) => c['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $type');
    }
  }

  /// The sync bookkeeping tables: an activity log (drives the dashboard bell),
  /// a registry of linked devices, and a single sync_state row holding the Drive
  /// folder/file ids and last-sync high-water marks.
  static Future<void> _createSyncTables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_log (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        sync_type     TEXT NOT NULL,
        table_name    TEXT,
        records_count INTEGER DEFAULT 0,
        device_source TEXT,
        description   TEXT,
        synced_at     TEXT DEFAULT (datetime('now')),
        is_read       INTEGER DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS devices (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        device_id   TEXT NOT NULL UNIQUE,
        device_name TEXT,
        device_type TEXT NOT NULL CHECK(device_type IN ('android','windows')),
        linked_at   TEXT DEFAULT (datetime('now')),
        last_seen   TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_state (
        id                      INTEGER PRIMARY KEY AUTOINCREMENT,
        business_id             INTEGER NOT NULL,
        last_sync_at            TEXT,
        last_upload_at          TEXT,
        last_download_at        TEXT,
        drive_folder_id         TEXT,
        android_changes_file_id TEXT,
        windows_changes_file_id TEXT
      )
    ''');

    // Seed the single sync_state row so the engine can always UPDATE it.
    final existing = await db.rawQuery('SELECT COUNT(*) AS c FROM sync_state');
    if (((existing.first['c'] as int?) ?? 0) == 0) {
      await db.insert('sync_state', {'business_id': 1});
    }
  }

  /// AFTER INSERT triggers that stamp `uuid` (and `device_id` where the column
  /// exists) on any new row in a synced table. This captures inserts made by the
  /// existing repositories without changing a single repository — they keep
  /// calling db.insert and the trigger fills the sync metadata.
  ///
  /// uuid is generated as a 36-char canonical v4-shaped string from randomblob,
  /// so it interoperates with Dart's Uuid().v4() on the other device (both are
  /// just opaque unique keys for matching). device_id is read from the
  /// `sync_device_id` settings row (NULL until the device registers — harmless;
  /// the engine backfills it on first sync).
  static Future<void> _createSyncTriggers(Database db) async {
    for (final t in syncedTables) {
      // Whether this table has a device_id column to stamp.
      final cols = await db.rawQuery('PRAGMA table_info($t)');
      final hasDevice = cols.any((c) => c['name'] == 'device_id');
      final deviceClause = hasDevice
          ? ", device_id = COALESCE(NEW.device_id, "
              "(SELECT value FROM settings WHERE business_id = 1 AND key = 'sync_device_id'))"
          : '';
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_sync_uuid_$t
        AFTER INSERT ON $t
        WHEN NEW.uuid IS NULL
        BEGIN
          UPDATE $t
          SET uuid = (
            lower(hex(randomblob(4))) || '-' ||
            lower(hex(randomblob(2))) || '-4' ||
            substr(lower(hex(randomblob(2))), 2) || '-' ||
            substr('89ab', abs(random()) % 4 + 1, 1) ||
            substr(lower(hex(randomblob(2))), 2) || '-' ||
            lower(hex(randomblob(6)))
          )$deviceClause
          WHERE id = NEW.id;
        END
      ''');
    }
  }

  /// AFTER UPDATE triggers that mark a synced row dirty (is_synced = 0) when the
  /// app edits it, so the edit re-uploads on the next sync.
  ///
  /// The guard distinguishes an app edit from a sync-merge write:
  ///   - App edits don't touch is_synced, so NEW.is_synced = OLD.is_synced. When
  ///     the row was previously synced (OLD.is_synced = 1) we flip it to 0.
  ///   - The merge (updateFromSync) sets is_synced = 1 explicitly, so
  ///     NEW.is_synced (1) <> OLD.is_synced (often 0) → guard fails → no flip,
  ///     preventing a cross-device bounce loop.
  /// After the trigger sets is_synced = 0, any recursive fire sees
  /// NEW.is_synced = OLD.is_synced = 0 → guard's "= 1" fails → stops. (Recursive
  /// triggers are off by default regardless.)
  static Future<void> _createSyncUpdateTriggers(Database db) async {
    for (final t in syncedTables) {
      final cols = await db.rawQuery('PRAGMA table_info($t)');
      if (!cols.any((c) => c['name'] == 'is_synced')) continue;
      await db.execute('''
        CREATE TRIGGER IF NOT EXISTS trg_sync_dirty_$t
        AFTER UPDATE ON $t
        WHEN NEW.is_synced = OLD.is_synced AND OLD.is_synced = 1
        BEGIN
          UPDATE $t SET is_synced = 0 WHERE id = NEW.id;
        END
      ''');
    }
  }

  /// One-time backfill: give every pre-existing row a uuid. Runs after the
  /// triggers exist, but operates on rows inserted before them (seed data on a
  /// fresh DB, or the user's real data on upgrade). Uses the same generation
  /// expression as the trigger for consistency.
  static Future<void> _backfillSyncUuids(Database db) async {
    for (final t in syncedTables) {
      await db.execute('''
        UPDATE $t SET uuid = (
          lower(hex(randomblob(4))) || '-' ||
          lower(hex(randomblob(2))) || '-4' ||
          substr(lower(hex(randomblob(2))), 2) || '-' ||
          substr('89ab', abs(random()) % 4 + 1, 1) ||
          substr(lower(hex(randomblob(2))), 2) || '-' ||
          lower(hex(randomblob(6)))
        )
        WHERE uuid IS NULL
      ''');
    }
  }

  // ─────────────────────────────────────────
  // INDEXES
  // ─────────────────────────────────────────

  static Future<void> _createIndexes(Database db) async {
    await db.execute('CREATE INDEX idx_parties_business ON parties(business_id)');
    await db.execute('CREATE INDEX idx_parties_type     ON parties(party_type)');
    await db.execute('CREATE INDEX idx_parties_phone    ON parties(phone)');
    await db.execute('CREATE INDEX idx_items_business   ON items(business_id)');
    await db.execute('CREATE INDEX idx_items_category   ON items(category_id)');
    await db.execute('CREATE INDEX idx_items_barcode    ON items(barcode)');
    await db.execute('CREATE INDEX idx_items_sku        ON items(sku)');
    await db.execute('CREATE INDEX idx_item_units_item  ON item_units(item_id)');
    await db.execute('CREATE INDEX idx_txn_business     ON transactions(business_id)');
    await db.execute('CREATE INDEX idx_txn_party        ON transactions(party_id)');
    await db.execute('CREATE INDEX idx_txn_type         ON transactions(transaction_type)');
    await db.execute('CREATE INDEX idx_txn_date         ON transactions(transaction_date)');
    await db.execute('CREATE INDEX idx_txn_status       ON transactions(payment_status)');
    await db.execute('CREATE INDEX idx_txn_number       ON transactions(transaction_number)');
    await db.execute('CREATE INDEX idx_txn_items_txn    ON transaction_items(transaction_id)');
    await db.execute('CREATE INDEX idx_txn_items_item   ON transaction_items(item_id)');
    await db.execute('CREATE INDEX idx_payments_txn     ON payments(transaction_id)');
  }

  // ─────────────────────────────────────────
  // TRIGGERS
  // ─────────────────────────────────────────

  static Future<void> _createTriggers(Database db) async {
    await _createStockTriggers(db);
    await _createPaymentTriggers(db);
  }

  /// The three payment-side triggers (account balance ± and transaction
  /// payment-status derivation). Extracted so the v10 migration can drop and
  /// recreate them with the sync guard.
  ///
  /// Each guards on `COALESCE(NEW.is_synced, 0) = 0` so it fires only for
  /// locally-created payments. A sync-merged payment already carries the source
  /// device's account-balance effect and the transaction's pre-derived
  /// paid_amount/balance_amount/payment_status; without the guard these triggers
  /// would double-count the balance and corrupt the payment status on every sync.
  static Future<void> _createPaymentTriggers(Database db) async {
    // Account balance increases on payment_in or sale (cash payment)
    await db.execute('''
      CREATE TRIGGER trg_account_balance_increase
      AFTER INSERT ON payments
      WHEN NEW.account_id IS NOT NULL
        AND COALESCE(NEW.is_synced, 0) = 0
        AND (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id)
            IN ('sale', 'payment_in', 'other_income')
      BEGIN
        UPDATE accounts
        SET current_balance = current_balance + NEW.amount,
            updated_at      = datetime('now')
        WHERE id = NEW.account_id;
      END
    ''');

    // Account balance decreases on payment_out or purchase (cash payment)
    await db.execute('''
      CREATE TRIGGER trg_account_balance_decrease
      AFTER INSERT ON payments
      WHEN NEW.account_id IS NOT NULL
        AND COALESCE(NEW.is_synced, 0) = 0
        AND (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id)
            IN ('purchase', 'payment_out', 'expense')
      BEGIN
        UPDATE accounts
        SET current_balance = current_balance - NEW.amount,
            updated_at      = datetime('now')
        WHERE id = NEW.account_id;
      END
    ''');

    // Auto-update transaction balance_amount and payment_status after each payment
    await db.execute('''
      CREATE TRIGGER trg_update_transaction_payment_status
      AFTER INSERT ON payments
      WHEN COALESCE(NEW.is_synced, 0) = 0
      BEGIN
        UPDATE transactions
        SET paid_amount    = paid_amount + NEW.amount,
            balance_amount = total_amount - (paid_amount + NEW.amount),
            payment_status = CASE
              WHEN (paid_amount + NEW.amount) >= total_amount THEN 'paid'
              WHEN (paid_amount + NEW.amount) > 0             THEN 'partial'
              ELSE 'unpaid'
            END,
            updated_at = datetime('now')
        WHERE id = NEW.transaction_id;
      END
    ''');
  }

  /// The four stock-movement triggers. Extracted so the v3 migration can drop
  /// and recreate them with the conversion-factor logic.
  ///
  /// Each guards on `COALESCE(NEW.is_synced, 0) = 0` so it fires only for rows
  /// the user creates *locally*. Sync-merged rows arrive with their stock effect
  /// already applied on the source device (and is_synced = 1); without this
  /// guard the trigger would re-apply it here, doubling stock on every sync.
  static Future<void> _createStockTriggers(Database db) async {
    // Stock decreases when a sale line item is inserted
    await db.execute('''
      CREATE TRIGGER trg_stock_decrease_on_sale
      AFTER INSERT ON transaction_items
      WHEN (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id) = 'sale'
        AND NEW.item_id IS NOT NULL
        AND COALESCE(NEW.is_synced, 0) = 0
      BEGIN
        UPDATE items
        SET current_stock = current_stock - (NEW.quantity * COALESCE(NEW.conversion_factor, 1)),
            updated_at    = datetime('now')
        WHERE id = NEW.item_id;
      END
    ''');

    // Stock increases when a sale return line item is inserted
    await db.execute('''
      CREATE TRIGGER trg_stock_increase_on_sale_return
      AFTER INSERT ON transaction_items
      WHEN (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id) = 'sale_return'
        AND NEW.item_id IS NOT NULL
        AND COALESCE(NEW.is_synced, 0) = 0
      BEGIN
        UPDATE items
        SET current_stock = current_stock + (NEW.quantity * COALESCE(NEW.conversion_factor, 1)),
            updated_at    = datetime('now')
        WHERE id = NEW.item_id;
      END
    ''');

    // Stock increases when a purchase line item is inserted
    await db.execute('''
      CREATE TRIGGER trg_stock_increase_on_purchase
      AFTER INSERT ON transaction_items
      WHEN (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id) = 'purchase'
        AND NEW.item_id IS NOT NULL
        AND COALESCE(NEW.is_synced, 0) = 0
      BEGIN
        UPDATE items
        SET current_stock = current_stock + (NEW.quantity * COALESCE(NEW.conversion_factor, 1)),
            updated_at    = datetime('now')
        WHERE id = NEW.item_id;
      END
    ''');

    // Stock decreases when a purchase return line item is inserted
    await db.execute('''
      CREATE TRIGGER trg_stock_decrease_on_purchase_return
      AFTER INSERT ON transaction_items
      WHEN (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id) = 'purchase_return'
        AND NEW.item_id IS NOT NULL
        AND COALESCE(NEW.is_synced, 0) = 0
      BEGIN
        UPDATE items
        SET current_stock = current_stock - (NEW.quantity * COALESCE(NEW.conversion_factor, 1)),
            updated_at    = datetime('now')
        WHERE id = NEW.item_id;
      END
    ''');
  }

  // ─────────────────────────────────────────
  // SEED DATA
  // ─────────────────────────────────────────

  static Future<void> _seedDefaultData(Database db) async {
    // Default business (single-firm mode).
    // books_beginning_date defaults to the moment the user first sets up the
    // app (first DB creation), matching Vyapar's behaviour.
    await db.insert('businesses', {
      'name': 'My Business',
      'country': 'India',
      'currency_code': 'INR',
      'currency_symbol': '₹',
      'financial_year_start': '04-01',
      'books_beginning_date': DateTime.now().toIso8601String(),
      'invoice_prefix': 'INV',
      'invoice_counter': 1,
      'purchase_prefix': 'PUR',
      'purchase_counter': 1,
      'receipt_counter': 1,
      'is_active': 1,
    });

    // Default settings
    final settingsList = [
      {'key': 'date_format', 'value': 'dd/MM/yyyy'},
      {'key': 'decimal_places', 'value': '2'},
      {'key': 'tax_enabled', 'value': '1'},
      {'key': 'stock_tracking', 'value': '1'},
      {'key': 'low_stock_alert', 'value': '1'},
      {'key': 'theme', 'value': 'light'},
      {'key': 'invoice_template', 'value': 'template_1'},
      {'key': 'show_discount', 'value': '1'},
      {'key': 'default_payment_mode', 'value': 'cash'},
      {'key': 'backup_reminder_days', 'value': '7'},
      {'key': 'company_setup_done', 'value': '0'},
      // WhatsApp invoice sharing (see AppStrings.kWhatsapp*). Auto-prompt and
      // owner-send default on; customer-send is opt-in. Upgraders fall back to
      // these defaults via getSetting(defaultVal:) — no migration needed.
      {'key': 'whatsapp_auto_prompt', 'value': '1'},
      {'key': 'whatsapp_owner_send', 'value': '1'},
      {'key': 'whatsapp_customer_send', 'value': '0'},
      // Invoice Format 1 (GST tax invoice with transport fields + 3 copies)
      // and Estimate Format 2 (quotation layout with Unit column + terms).
      {'key': 'print_invoice_format', 'value': 'format1'},
      {'key': 'print_estimate_format', 'value': 'format2'},
      // Phase 6 Layer 1: optional device-local PIN lock. Hash is empty until the
      // user sets a PIN; it is the SHA-256 of the PIN, never the PIN itself.
      {'key': 'security_pin_enabled', 'value': '0'},
      {'key': 'security_pin_hash', 'value': ''},
    ];
    for (final s in settingsList) {
      await db.insert('settings', {'business_id': 1, ...s});
    }

    // Default units
    final unitsList = [
      {'name': 'Piece', 'short_name': 'pcs'},
      {'name': 'Kilogram', 'short_name': 'kg'},
      {'name': 'Gram', 'short_name': 'gm'},
      {'name': 'Litre', 'short_name': 'ltr'},
      {'name': 'Millilitre', 'short_name': 'ml'},
      {'name': 'Metre', 'short_name': 'mtr'},
      {'name': 'Box', 'short_name': 'box'},
      {'name': 'Dozen', 'short_name': 'dz'},
      {'name': 'Bag', 'short_name': 'bag'},
      {'name': 'Number', 'short_name': 'nos'},
    ];
    for (final u in unitsList) {
      await db.insert('units', {'business_id': 1, ...u});
    }

    // Default tax rates
    final taxList = [
      {'name': 'No Tax', 'rate': 0.0, 'cgst_rate': 0.0, 'sgst_rate': 0.0, 'igst_rate': 0.0},
      {'name': 'GST 3%', 'rate': 3.0, 'cgst_rate': 1.5, 'sgst_rate': 1.5, 'igst_rate': 3.0},
      {'name': 'GST 5%', 'rate': 5.0, 'cgst_rate': 2.5, 'sgst_rate': 2.5, 'igst_rate': 5.0},
      {'name': 'GST 12%', 'rate': 12.0, 'cgst_rate': 6.0, 'sgst_rate': 6.0, 'igst_rate': 12.0},
      {'name': 'GST 18%', 'rate': 18.0, 'cgst_rate': 9.0, 'sgst_rate': 9.0, 'igst_rate': 18.0},
      {'name': 'GST 28%', 'rate': 28.0, 'cgst_rate': 14.0, 'sgst_rate': 14.0, 'igst_rate': 28.0},
    ];
    for (final t in taxList) {
      await db.insert('tax_rates', {'business_id': 1, ...t});
    }

    // Default payment modes
    final paymentModes = [
      {'name': 'Cash', 'type': 'cash'},
      {'name': 'UPI', 'type': 'digital'},
      {'name': 'Bank Transfer', 'type': 'digital'},
      {'name': 'Cheque', 'type': 'digital'},
      {'name': 'Card', 'type': 'digital'},
      {'name': 'Credit', 'type': 'credit'},
    ];
    for (final p in paymentModes) {
      await db.insert('payment_modes', {'business_id': 1, ...p});
    }

    // Default expense categories
    final expenseCategories = [
      {'name': 'Rent', 'category_for': 'expense'},
      {'name': 'Salaries', 'category_for': 'expense'},
      {'name': 'Electricity', 'category_for': 'expense'},
      {'name': 'Transport', 'category_for': 'expense'},
      {'name': 'Packaging', 'category_for': 'expense'},
      {'name': 'Marketing', 'category_for': 'expense'},
      {'name': 'Office Supplies', 'category_for': 'expense'},
      {'name': 'Maintenance', 'category_for': 'expense'},
      {'name': 'Interest Paid', 'category_for': 'expense'},
      {'name': 'Miscellaneous', 'category_for': 'both'},
      {'name': 'Commission', 'category_for': 'income'},
      {'name': 'Interest Received', 'category_for': 'income'},
      {'name': 'Rental Income', 'category_for': 'income'},
      {'name': 'Other Income', 'category_for': 'income'},
    ];
    for (final c in expenseCategories) {
      await db.insert('expense_categories', {'business_id': 1, ...c});
    }

    // Default accounts
    await db.insert('accounts', {
      'business_id': 1,
      'name': 'Cash',
      'account_type': 'cash',
      'opening_balance': 0.0,
      'current_balance': 0.0,
      'is_default': 1,
      'is_active': 1,
    });

    // Default print settings (45 keys). Pre-inserted here so a fresh install
    // has every print_* key with its default value.
    await preInsertPrintSettings(db);
  }

  /// Pre-inserts all 45 `print_*` settings keys for business 1 with their
  /// default values. Uses [ConflictAlgorithm.ignore] so existing user choices
  /// are never overwritten — making this safe to call from both [_seedDefaultData]
  /// (fresh install) and the v11 [_onUpgrade] step (existing installs). The keys
  /// here are the canonical source the future Settings phase reads, so it needs
  /// no migration of its own.
  static Future<void> preInsertPrintSettings(Database db) async {
    const defaults = {
      'print_thermal_default': '0',
      'print_paper_size': 'mm80',
      'print_copies': '1',
      'print_extra_lines': '0',
      'print_auto_cut': '0',
      'print_cash_drawer': '0',
      'print_text_styling': '1',
      'print_regular_text_size': 'medium',
      'print_page_size': 'A4',
      'print_orientation': 'portrait',
      'print_repeat_header': '1',
      'print_original_duplicate': '0',
      'print_extra_top_space': '0',
      'print_min_item_rows': '0',
      'print_company_name': '1',
      'print_company_name_size': 'large',
      'print_logo': '1',
      'print_address': '1',
      'print_email': '1',
      'print_phone': '1',
      'print_gstin': '1',
      'print_show_sno': '1',
      'print_show_hsn': '1',
      'print_show_unit': '1',
      'print_show_mrp': '1',
      'print_show_description': '1',
      'print_show_total_qty': '1',
      'print_amount_decimal': '1',
      'print_received_amount': '1',
      'print_balance_amount': '1',
      'print_party_balance': '0',
      'print_tax_details': '1',
      'print_amount_grouping': '1',
      'print_amount_words_format': 'indian',
      'print_you_saved': '1',
      'print_description': '1',
      'print_terms': '1',
      'print_terms_text': 'Thank you for your business!',
      'print_received_by': '1',
      'print_delivered_by': '1',
      'print_signature': '1',
      'print_signature_text': 'Authorized Signatory',
      'print_payment_mode': '0',
      'print_page_numbers': '1',
      'print_acknowledgement': '0',
    };
    final batch = db.batch();
    defaults.forEach((key, value) {
      batch.insert(
        'settings',
        {'business_id': 1, 'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    });
    await batch.commit(noResult: true);
  }

  // ─────────────────────────────────────────
  // HELPERS
  // ─────────────────────────────────────────

  static Future<int> getSetting(String key, {int defaultVal = 0}) async {
    final db = await database;
    final rows = await db.query(
      'settings',
      where: 'business_id = 1 AND key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return defaultVal;
    return int.tryParse(rows.first['value'] as String? ?? '') ?? defaultVal;
  }

  static Future<String> getSettingStr(String key, {String defaultVal = ''}) async {
    final db = await database;
    final rows = await db.query(
      'settings',
      where: 'business_id = 1 AND key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return defaultVal;
    return rows.first['value'] as String? ?? defaultVal;
  }

  static Future<void> setSetting(String key, String value) async {
    final db = await database;
    await db.insert(
      'settings',
      {'business_id': 1, 'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<Map<String, dynamic>?> getBusiness() async {
    final db = await database;
    final rows = await db.query('businesses', where: 'id = 1', limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  static Future<void> updateBusiness(Map<String, dynamic> data) async {
    final db = await database;
    await db.update(
      'businesses',
      {...data, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = 1',
    );
  }

  /// Per-device document-number prefix. Windows prepends `W-` to every generated
  /// number (W-INV-0001, W-PUR-0001, W-1, W-CN 1, …) so the two devices can never
  /// produce the same id — same id for two different bills would corrupt
  /// reports/ledgers after sync. Android (and any other platform) uses no prefix,
  /// so its existing numbering is untouched.
  static String get deviceDocPrefix => Platform.isWindows ? 'W-' : '';

  // ─────────────────────────────────────────
  // PER-PREFIX DOCUMENT NUMBERING
  // ─────────────────────────────────────────
  //
  // Counters are stored as settings keyed `counter_<type>_<PREFIX>` (e.g.
  // counter_sale_INV) rather than a single column per type. This way, changing
  // the prefix starts a fresh sequence for the new prefix and never reuses or
  // collides with numbers issued under the old prefix — switching INV→JUNE
  // doesn't make JUNE-0001 clash with the next INV number.
  //
  // The legacy `invoice_counter` / `purchase_counter` columns on the business
  // row are the seed for the *current* prefix's key the first time it's used, so
  // an existing install's running sequence continues unbroken. They are no
  // longer incremented once the per-prefix key exists.

  /// The active prefix for [type] ('sale' | 'purchase'). In Monthly mode
  /// (settings key `prefix_mode_<type>` = 'monthly') this is the current month
  /// name, recomputed live so a new month automatically starts a fresh
  /// `counter_<type>_<MONTH>` sequence. Otherwise it's the custom prefix stored
  /// on the business row (invoice_prefix / purchase_prefix).
  static Future<String> prefixFor(String type) async {
    final mode = await getSettingStr('prefix_mode_$type', defaultVal: 'custom');
    if (mode == 'monthly') return monthlyPrefix();
    final biz = await getBusiness();
    return switch (type) {
      'purchase' => (biz?['purchase_prefix'] as String?) ?? 'PUR',
      _ => (biz?['invoice_prefix'] as String?) ?? 'INV',
    };
  }

  /// The next counter value for [type]'s current prefix, *without* consuming it.
  /// Seeds from the legacy column counter the first time a prefix is seen.
  static Future<int> _peekCounter(String type, String prefix) async {
    final key = 'counter_${type}_$prefix';
    final existing = await getSettingStr(key);
    if (existing.isNotEmpty) {
      return int.tryParse(existing) ?? 1;
    }
    // First use of this prefix: seed from the legacy column so an in-progress
    // sequence continues. A brand-new prefix (no matching column) starts at 1.
    final biz = await getBusiness();
    final seed = switch (type) {
      'purchase' => (biz?['purchase_counter'] as int?) ?? 1,
      _ => (biz?['invoice_counter'] as int?) ?? 1,
    };
    return seed;
  }

  /// Reads the next full document number for [type] without consuming the
  /// counter (used by the form to display the number before save).
  static Future<String> peekDocNumber(String type) async {
    final prefix = await prefixFor(type);
    final counter = await _peekCounter(type, prefix);
    return '$deviceDocPrefix$prefix-${counter.toString().padLeft(4, '0')}';
  }

  /// Consumes and returns the next document number for [type], advancing the
  /// per-prefix counter. Call this exactly once when a document is saved.
  static Future<String> consumeDocNumber(String type) async {
    final prefix = await prefixFor(type);
    final counter = await _peekCounter(type, prefix);
    await setSetting('counter_${type}_$prefix', '${counter + 1}');
    return '$deviceDocPrefix$prefix-${counter.toString().padLeft(4, '0')}';
  }

  /// The current month as an uppercase prefix (e.g. 'JUNE'), for the Monthly
  /// prefix mode. A new month yields a new prefix, which rolls a fresh
  /// `counter_<type>_<MONTH>` sequence automatically (the monthly "reset").
  static String monthlyPrefix([DateTime? when]) {
    const months = [
      'JANUARY', 'FEBRUARY', 'MARCH', 'APRIL', 'MAY', 'JUNE',
      'JULY', 'AUGUST', 'SEPTEMBER', 'OCTOBER', 'NOVEMBER', 'DECEMBER',
    ];
    return months[(when ?? DateTime.now()).month - 1];
  }

  /// Live-preview number for an arbitrary [prefix] without changing the saved
  /// prefix or consuming the counter. Used by the prefix-settings screen.
  static Future<String> previewDocNumber(String type, String prefix) async {
    final counter = await _peekCounter(type, prefix);
    return '$deviceDocPrefix$prefix-${counter.toString().padLeft(4, '0')}';
  }

  /// Resets the per-prefix counter for [type]/[prefix] back to 1. Used by the
  /// prefix-settings "reset counter" action.
  static Future<void> resetCounter(String type, String prefix) =>
      setSetting('counter_${type}_$prefix', '1');

  /// Consumes the next sale-invoice number (per-prefix). Retained name for the
  /// existing callers; delegates to [consumeDocNumber].
  static Future<String> nextInvoiceNumber() => consumeDocNumber('sale');

  /// Consumes the next purchase number (per-prefix).
  static Future<String> nextPurchaseNumber() => consumeDocNumber('purchase');

  static Future<String> nextReceiptNumber() async {
    final db = await database;
    final biz = await getBusiness();
    final counter = (biz?['receipt_counter'] as int?) ?? 1;
    final number = '$deviceDocPrefix$counter';
    await db.update(
      'businesses',
      {'receipt_counter': counter + 1},
      where: 'id = 1',
    );
    return number;
  }

  /// Peek at the next receipt number without consuming the counter.
  static Future<String> peekReceiptNumber() async {
    final biz = await getBusiness();
    return '$deviceDocPrefix${(biz?['receipt_counter'] as int?) ?? 1}';
  }

  // ─────────────────────────────────────────
  // ATOMIC IN-TRANSACTION DOCUMENT NUMBERING
  // ─────────────────────────────────────────
  //
  // The methods above (peek*/consume*/nextReceiptNumber) are now used ONLY for
  // the read-only preview a form shows before save. The authoritative number is
  // minted by [mintDocNumberInTxn] *inside* the same DB transaction that inserts
  // the row, so the read-modify-write of the counter and the insert that uses it
  // commit together. Two concurrent saves can no longer read the same counter
  // value (peek-then-consume-later was the source of duplicate INV/PUR/EST/
  // receipt numbers under "Save & New", rapid taps, and convert-to-sale), and
  // estimates / challans / returns / orders — which previously derived their
  // number from a racy `count(*) + 1` and never reserved it — now hold a real
  // per-prefix counter seeded once from that count.

  /// Fixed prefix for the count-derived document types that have no
  /// user-configurable prefix. Sale/purchase use [prefixFor] instead.
  static const Map<String, String> _fixedDocPrefix = {
    'estimate': 'EST',
    'delivery_challan': 'DC',
    'sale_return': 'CN',
    'purchase_return': 'PR',
    'purchase_order': 'PO',
    'sale_order': 'SO',
  };

  /// Padding width per type (matches the legacy display formats so existing and
  /// new numbers look identical).
  static int _padFor(String type) => switch (type) {
        'purchase_order' => 2,
        _ => 4,
      };

  /// Resolves the active prefix for any document [type] using [sql] for the
  /// monthly-mode / business-row reads so it stays inside the open transaction.
  static Future<String> _prefixForInTxn(Transaction sql, String type) async {
    final fixed = _fixedDocPrefix[type];
    if (fixed != null) return fixed;
    if (type == 'sale' || type == 'purchase') {
      final mode = await _getSettingStrInTxn(sql, 'prefix_mode_$type',
          defaultVal: 'custom');
      if (mode == 'monthly') return monthlyPrefix();
      final biz = await sql.query('businesses', where: 'id = 1', limit: 1);
      final row = biz.isEmpty ? null : biz.first;
      return type == 'purchase'
          ? (row?['purchase_prefix'] as String?) ?? 'PUR'
          : (row?['invoice_prefix'] as String?) ?? 'INV';
    }
    return type.toUpperCase();
  }

  static Future<String> _getSettingStrInTxn(Transaction sql, String key,
      {String defaultVal = ''}) async {
    final rows = await sql.query('settings',
        where: 'business_id = 1 AND key = ?', whereArgs: [key], limit: 1);
    if (rows.isEmpty) return defaultVal;
    return rows.first['value'] as String? ?? defaultVal;
  }

  static Future<void> _setSettingInTxn(
      Transaction sql, String key, String value) async {
    await sql.insert('settings', {'business_id': 1, 'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// First-use seed for a brand-new `counter_<type>_<prefix>` key, computed on
  /// the transaction handle so it observes uncommitted rows from this same txn.
  ///
  /// - sale/purchase seed from the legacy business-row counter column (continues
  ///   an in-progress sequence), or 1 for a new prefix.
  /// - count-derived types (estimate/challan/returns/orders) seed from how many
  ///   such documents already exist + 1, so existing data isn't renumbered.
  static Future<int> _seedCounterInTxn(
      Transaction sql, String type, String prefix) async {
    if (type == 'sale' || type == 'purchase') {
      final biz = await sql.query('businesses', where: 'id = 1', limit: 1);
      final row = biz.isEmpty ? null : biz.first;
      return type == 'purchase'
          ? (row?['purchase_counter'] as int?) ?? 1
          : (row?['invoice_counter'] as int?) ?? 1;
    }
    // count-derived types: seed past the HIGHEST numeric suffix already in use
    // for this type (not the row count) so a sparse or partly-deleted history
    // can't make the seed reissue a number that still exists. We scan every
    // such row once (first-use only) and take max(trailing integer) + 1. Rows
    // from the other device carry a `W-` prefix but the same trailing integer
    // shape, so they're considered too.
    final rows = await sql.query('transactions',
        columns: ['transaction_number'],
        where: 'business_id = 1 AND transaction_type = ?',
        whereArgs: [type]);
    var maxN = 0;
    final trailing = RegExp(r'(\d+)\s*$');
    for (final r in rows) {
      final num = r['transaction_number'] as String?;
      if (num == null) continue;
      final m = trailing.firstMatch(num);
      if (m == null) continue;
      final n = int.tryParse(m.group(1)!) ?? 0;
      if (n > maxN) maxN = n;
    }
    return maxN + 1;
  }

  /// Formats counter [n] into the full document number for [type] (per-device
  /// prefix included). Single source of truth for the on-screen shape so the
  /// preview ([peekDocNumberForType]) and the authoritative mint
  /// ([mintDocNumberInTxn]) can never drift apart.
  static String _formatDocNumber(String type, String prefix, int n) {
    final body = switch (type) {
      'sale_return' => 'CN $n',
      'purchase_return' => 'PR-$n',
      _ => '$prefix-${n.toString().padLeft(_padFor(type), '0')}',
    };
    return '$deviceDocPrefix$body';
  }

  /// The next document number for [type] WITHOUT consuming the counter, for the
  /// form's read-only preview. Mirrors [mintDocNumberInTxn]'s prefix/seed/format
  /// exactly so the previewed number matches what will be saved. Works for
  /// sale, purchase, estimate, challan, returns and orders (not the receipt
  /// types, which use [peekReceiptNumber]).
  static Future<String> peekDocNumberForType(String type) async {
    final db = await database;
    final prefix = await db.transaction(
        (sql) async => _prefixForInTxn(sql, type));
    final key = 'counter_${type}_$prefix';
    final existing = await getSettingStr(key);
    final int counter;
    if (existing.isNotEmpty) {
      counter = int.tryParse(existing) ?? 1;
    } else {
      counter = await db.transaction(
          (sql) async => _seedCounterInTxn(sql, type, prefix));
    }
    return _formatDocNumber(type, prefix, counter);
  }

  /// Atomically reads, increments, and persists the per-prefix counter for
  /// [type] on the open transaction [sql], returning the full document number
  /// (with the per-device `W-` prefix on Windows). MUST be called from inside a
  /// `db.transaction(...)` block, before the insert that stores the returned
  /// number, so the counter advance and the insert commit together.
  ///
  /// `payment_in` / `payment_out` share the single legacy `receipt_counter`
  /// column on the business row (Vyapar-style plain receipt numbers: 1, 2, 3…).
  static Future<String> mintDocNumberInTxn(
      Transaction sql, String type) async {
    if (type == 'payment_in' || type == 'payment_out') {
      final biz = await sql.query('businesses',
          columns: ['receipt_counter'], where: 'id = 1', limit: 1);
      final counter =
          biz.isEmpty ? 1 : (biz.first['receipt_counter'] as int?) ?? 1;
      await sql.update('businesses', {'receipt_counter': counter + 1},
          where: 'id = 1');
      return '$deviceDocPrefix$counter';
    }

    final prefix = await _prefixForInTxn(sql, type);
    final key = 'counter_${type}_$prefix';
    final existing = await _getSettingStrInTxn(sql, key);
    final counter = existing.isNotEmpty
        ? (int.tryParse(existing) ?? 1)
        : await _seedCounterInTxn(sql, type, prefix);
    await _setSettingInTxn(sql, key, '${counter + 1}');
    // Sale/purchase format as PREFIX-0001; count-derived types keep their legacy
    // shapes: "CN 1" (space, no pad), "PR-1" (no pad), "PO-01" / "EST-0001" / etc.
    return _formatDocNumber(type, prefix, counter);
  }

  // ─────────────────────────────────────────
  // SYNC HELPERS (Phase 5)
  // ─────────────────────────────────────────

  /// This device's stable sync id, created on first call and persisted in
  /// settings. The insert triggers read it (key `sync_device_id`) to stamp new
  /// rows, so it must exist before the first write that should be attributed.
  static Future<String> getOrCreateDeviceId() async {
    var id = await getSettingStr('sync_device_id');
    if (id.isEmpty) {
      // A v4-shaped id; generated here rather than importing uuid into the DB
      // layer to keep this file dependency-free.
      final db = await database;
      final rows = await db.rawQuery('''
        SELECT (
          lower(hex(randomblob(4))) || '-' ||
          lower(hex(randomblob(2))) || '-4' ||
          substr(lower(hex(randomblob(2))), 2) || '-' ||
          substr('89ab', abs(random()) % 4 + 1, 1) ||
          substr(lower(hex(randomblob(2))), 2) || '-' ||
          lower(hex(randomblob(6)))
        ) AS id
      ''');
      id = rows.first['id'] as String;
      await setSetting('sync_device_id', id);
    }
    return id;
  }

  /// The single sync_state row (created in [_createSyncTables]).
  static Future<Map<String, dynamic>> syncState() async {
    final db = await database;
    final rows = await db.query('sync_state', where: 'id = 1', limit: 1);
    if (rows.isEmpty) {
      await db.insert('sync_state', {'business_id': 1});
      return (await db.query('sync_state', where: 'id = 1', limit: 1)).first;
    }
    return rows.first;
  }

  /// Patches the single sync_state row.
  static Future<void> updateSyncState(Map<String, dynamic> data) async {
    final db = await database;
    await db.update('sync_state', data, where: 'id = 1');
  }
}
