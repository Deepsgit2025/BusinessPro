import 'dart:io';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class DatabaseHelper {
  static const _dbName = 'business_pro.db';
  static const _dbVersion = 6;

  static Database? _db;

  static Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
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
    await _createIndexes(db);
    await _createTriggers(db);
    await _seedDefaultData(db);
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

    // Account balance increases on payment_in or sale (cash payment)
    await db.execute('''
      CREATE TRIGGER trg_account_balance_increase
      AFTER INSERT ON payments
      WHEN NEW.account_id IS NOT NULL
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
  static Future<void> _createStockTriggers(Database db) async {
    // Stock decreases when a sale line item is inserted
    await db.execute('''
      CREATE TRIGGER trg_stock_decrease_on_sale
      AFTER INSERT ON transaction_items
      WHEN (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id) = 'sale'
        AND NEW.item_id IS NOT NULL
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

  static Future<String> nextInvoiceNumber() async {
    final db = await database;
    final biz = await getBusiness();
    final prefix = biz?['invoice_prefix'] as String? ?? 'INV';
    final counter = (biz?['invoice_counter'] as int?) ?? 1;
    final number = '$prefix-${counter.toString().padLeft(4, '0')}';
    await db.update(
      'businesses',
      {'invoice_counter': counter + 1},
      where: 'id = 1',
    );
    return number;
  }

  static Future<String> nextPurchaseNumber() async {
    final db = await database;
    final biz = await getBusiness();
    final prefix = biz?['purchase_prefix'] as String? ?? 'PUR';
    final counter = (biz?['purchase_counter'] as int?) ?? 1;
    final number = '$prefix-${counter.toString().padLeft(4, '0')}';
    await db.update(
      'businesses',
      {'purchase_counter': counter + 1},
      where: 'id = 1',
    );
    return number;
  }

  static Future<String> nextReceiptNumber() async {
    final db = await database;
    final biz = await getBusiness();
    final counter = (biz?['receipt_counter'] as int?) ?? 1;
    final number = counter.toString();
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
    return ((biz?['receipt_counter'] as int?) ?? 1).toString();
  }
}
