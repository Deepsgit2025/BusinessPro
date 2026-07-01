# BusinessPro — CLAUDE.md

Offline-first accounting & invoicing app (Flutter), single-firm, Android + Windows.
Vyapar-style: parties, items, multi-tier unit pricing, sales/purchases, GST invoices,
inventory, employees/payroll, reports, thermal printing, on-device OCR, optional PIN
lock, two-way Google Drive sync.

This document describes the codebase **as it actually exists** (verified by reading
the source, not the design docs). Schema is read from
[database_helper.dart](lib/core/database/database_helper.dart). Status tags:
**[DONE]** wired & working · **[PARTIAL]** works but with gaps · **[STUB]** placeholder
that intentionally does nothing · **[BUGGY]** wired but has a real defect.

---

## Stack — what's actually in use

| Concern | Reality |
|---|---|
| **State management** | **Riverpod** (`flutter_riverpod` ^2.6.1), **hand-written providers only — NO code generation**. Confirmed in active use across ~60 files (~508 Riverpod API usages: `ConsumerWidget`, `ref.watch`/`ref.read`, `FutureProvider`, `StateProvider`, `Provider`, `.family`, `ProviderScope`). The codegen/lint deps (`riverpod_annotation`, `riverpod_generator`, `riverpod_lint`, `custom_lint`) were confirmed unused and **removed**. One exception: [app_lock_service.dart](lib/services/security/app_lock_service.dart) uses the Flutter SDK's `ChangeNotifier` as a singleton (`AppLockService.instance`), observed by the widget layer with a listenable builder — **not** a Riverpod provider, so integrate with it via `.instance` + a `ListenableBuilder`, not `ref.watch`. |
| **Navigation** | **`MaterialApp` with a `routes:` map + `Navigator.push`** ([main.dart](lib/main.dart)). (`go_router` was a dependency but used nowhere in `lib/` — **removed**.) |
| **Database** | SQLite via `sqflite` (Android) / `sqflite_common_ffi` (Windows/Linux). **Schema version 13.** WAL mode. All access through `DatabaseHelper` static methods + per-feature repositories. |
| **PDF / Print** | `pdf` + `printing` for documents; `flutter_blue_plus` (BT) + raw socket (network) for ESC/POS thermal. |
| **OCR** | `google_mlkit_text_recognition` (on-device, Android only). |
| **Sync** | Google Drive v3 **REST over `http`** (not `googleapis`), `google_sign_in` (Android token only), `cloud_firestore` (token relay + QR handoff only), `connectivity_plus`. |
| **Misc** | `crypto` (PIN SHA-256), `fl_chart` (reports), `signature`, `image_picker`, `share_plus`, `url_launcher`, `uuid`, `intl`, `file_picker`. |

Single business assumed throughout: repositories hardcode `_businessId = 1` and
settings/counters key on `business_id = 1`.

---

## Folder structure (real)

**Convention: feature-first.** App code lives under `lib/features/<feature>/`,
each feature owning its own `{screens,widgets,providers,models,repositories,
services,utils}` subfolders — there is **no** top-level `lib/screens/`, `lib/models/`,
or `lib/repositories/` layer holding the bulk of the app. Models and repositories
live *inside* their feature folder (e.g.
[transaction.dart](lib/features/transactions/models/transaction.dart),
[transaction_repository.dart](lib/features/transactions/repositories/transaction_repository.dart)).
Two deliberate hybrids break the pattern: cross-feature **services** are grouped
layer-first under `lib/services/<area>/` (sync, printer, ocr, backup, whatsapp,
security), and the **security UI** sits at `lib/screens/security/` +
`lib/widgets/security/` rather than in a `features/security/` folder. Shared
scaffolding (drawer, shell, empty-state) is under `lib/shared/widgets/`, and
app-wide constants/db/providers/utils under `lib/core/`.

```
lib/
├── main.dart                         # [DONE] entry; Firebase init, DB init, PIN preload, MaterialApp routes
├── firebase_options.dart             # generated Firebase config
├── core/
│   ├── constants/                    # app_colors, app_strings, app_theme, app_lists
│   ├── database/database_helper.dart # [DONE] schema v13, migrations, triggers, seed, doc-numbering, sync helpers
│   ├── providers/                    # business, notification, settings, theme providers
│   └── utils/                        # formatters, amount_to_words
├── features/
│   ├── dashboard/                    # [DONE] summary cards + quick actions + recent txns (recent list tappable → detail, routed by type)
│   ├── parties/                      # [DONE] customers/suppliers CRUD, detail, statement
│   ├── items/                        # [DONE] items, categories, units, tax rates, multi-tier unit pricing
│   ├── inventory/                    # [DONE] read-only stock views derived from transactions
│   ├── transactions/                 # [DONE] sale/purchase/returns/estimate/challan/payments + PDF + share
│   │                                 #        NOTE: one generic SaleDetailScreen renders ALL txn types — no per-type detail screen
│   ├── cash_bank/                    # [DONE] accounts, statement, money transfer
│   ├── expense/ + income/            # [DONE] income reuses ExpenseListScreen(isIncome: true)
│   ├── employees/                    # [DONE] employees, attendance, advances, salary payments, slip PDF
│   ├── reports/                      # [DONE] day book, P&L, outstanding, stock, sale/purchase, party statement
│   ├── company/                      # [DONE] company setup + shareable visiting card
│   ├── settings/                     # [DONE] settings, bill formats, prefix, printer, notification settings
│   ├── backup/                       # [PARTIAL] local backup/restore DONE; cloud list deferred
│   └── sync/                         # [DONE] QR link (show/scan), sync settings, sync notifications
├── screens/security/                 # [DONE] PIN setup, app lock, security settings
├── services/
│   ├── backup/                       # backup_manager [DONE]; google_drive_backup [STUB]; aws_s3_backup [STUB]
│   ├── ocr/                          # [DONE] bill_scanner_service (ML Kit), bill_parser
│   ├── printer/                      # BT/network [DONE]; usb [STUB-disabled]; manager, esc_pos, thermal formatter
│   ├── security/                     # [DONE] app_lock_service, pin_hash_util
│   ├── sync/                         # [DONE] auth, drive, qr_link, engine, repository, scheduler, models, providers
│   └── whatsapp/                     # [DONE] invoice share via WhatsApp / OS share sheet
├── shared/widgets/                   # app_drawer, main_shell, empty_state
└── widgets/security/                 # app_lock_wrapper, pin_input_widget
```

---

## Database schema (read from migration/init code, v13)

`onCreate` builds the v13 schema directly (it calls the same extracted helpers the
migrations use), so fresh installs and upgraded installs converge to identical schemas.

### Core tables (v1)
- **businesses** — single row (id=1). Profile, GST/bank/UPI fields, card visibility
  flags, invoice/purchase/receipt prefixes + counters, print-on-invoice toggles.
- **settings** — `(business_id, key)` unique KV store. Holds app settings, all 45
  `print_*` keys, doc-numbering counters (`counter_<type>_<PREFIX>`), sync state
  (`sync_device_id`, Drive token/email/expiry), PIN state.
- **parties** — customers/suppliers/both, opening balance (debit/credit), addresses.
- **party_addresses** — extra shipping addresses (cascade on party).
- **item_categories**, **units**, **tax_rates** (cgst/sgst/igst split).
- **items** — product/service, sale/purchase/MRP/wholesale prices, stock
  (`current_stock`, `opening_stock`, `min_stock_level`), tax, discount.
- **item_price_history**, **accounts** (cash/bank/wallet + `current_balance`),
  **payment_modes**, **expense_categories** (expense/income/both).
- **transactions** — the central document table. `transaction_type` CHECK includes:
  `sale, sale_return, sale_order, estimate, delivery_challan, purchase,
  purchase_return, purchase_order, expense, other_income, payment_in, payment_out`.
  Totals (subtotal/tax/cgst/sgst/igst/round_off/total/paid/balance), `payment_status`
  (paid/unpaid/partial), `status` (active/cancelled/draft/converted), `linked_transaction_id`
  (self-ref), soft-delete (`is_deleted`).
- **transaction_items** — line items; snapshots `item_name/hsn/unit_name`, `item_unit_id`
  + `conversion_factor` (for stock math), per-line tax split.
- **payments** — payment events against a transaction; account + mode.

### Migration history (each `if (oldVersion < N)` block, verified)
- **v2** — businesses: category, books_beginning_date, visiting-card visibility flags.
- **v3** — **multi-tier unit pricing**: `item_units` table; transaction_items gets
  `item_unit_id` + `conversion_factor`; stock triggers rebuilt to multiply by factor;
  one base-unit tier backfilled per item.
- **v4** — businesses: `print_bank_on_invoice`, `print_upi_qr_on_invoice`.
- **v5** — businesses: `receipt_counter`.
- **v6** — add `delivery_challan` to type CHECK (full **table rebuild**; drops/recreates
  triggers; FKs toggled OFF in `_onConfigure` for the pending v6 upgrade).
- **v7** — **employee module**: `employees` (daily_pay), `attendance`
  (present/half/absent, `day_value` snapshot, unique per employee+date).
- **v8** — **Phase 5 sync schema**: `uuid` on every synced table; `device_id`/
  `is_synced`/`server_updated_at` on tracked tables; `sync_log`/`devices`/`sync_state`
  tables; AFTER INSERT triggers stamp uuid+device_id; one-time UUID backfill.
- **v9** — AFTER UPDATE "dirty" triggers (`is_synced = 0` on local edit) — switched
  change detection from timestamp high-water mark to the `is_synced` flag.
- **v10** — guard stock + payment triggers with `COALESCE(NEW.is_synced,0)=0` so
  sync-merged rows don't double-apply stock/balance.
- **v11** — seed the 45 `print_*` keys for existing installs.
- **v12** — **Invoice Format 1**: transport/shipping columns on transactions
  (`eway_bill_number`, `place_of_supply`, `transport_name`, `vehicle_number`,
  `delivery_date/location`, `shipping_city/state/pincode`, `is_shipping_diff`);
  seed `print_invoice_format=format1`, `print_estimate_format=format2`.
- **v13** — **employee extensions**: employees `overtime_rate`/`advance_given`/
  `advance_paid`; attendance `overtime_hours` (OT rides on a logged day, not a 4th
  status); `salary_payments` + `employee_advances` tables.

### Triggers (verified present)
- **Stock** (4): decrease on sale, increase on sale_return, increase on purchase,
  decrease on purchase_return — multiply `quantity * conversion_factor`, guarded by
  `is_synced = 0`.
- **Payment** (3): account balance ±, and transaction paid/balance/payment_status
  derivation — guarded by `is_synced = 0`.
- **Sync** — per synced table: AFTER INSERT uuid/device_id stamp; AFTER UPDATE dirty flag.

### Synced tables (`syncedTables`)
`transactions, transaction_items, payments, parties, items, item_units, accounts,
expense_categories, item_categories`.

### Document numbering
Per-prefix counters in `settings` (`counter_sale_INV`, `counter_purchase_PUR`, …).
Supports custom and monthly prefix modes. **Windows prepends `W-`** to every number
(`deviceDocPrefix`) so two synced devices never mint the same id.

---

## Known-questionable spots — verified truth

The original brief flagged these four. Findings after reading the code:

### 1. Dashboard "To Collect / To Pay" — **[DONE], wired & correct**
[dashboard_screen.dart](lib/features/dashboard/screens/dashboard_screen.dart) `_SummaryRow`
watches `outstandingReceivablesProvider` / `outstandingPayablesProvider`
([transaction_providers.dart](lib/features/transactions/providers/transaction_providers.dart#L250)).
Both call `getOutstandingReceivables()` / `getOutstandingPayables()` →
`_outstandingForType()` in
[transaction_repository.dart](lib/features/transactions/repositories/transaction_repository.dart#L124),
which runs:
```sql
SELECT COALESCE(SUM(total_amount - paid_amount), 0)
FROM transactions
WHERE business_id=? AND transaction_type=? AND is_deleted=0
  AND status != 'cancelled' AND balance_amount > 0
```
Receivables = `sale`, payables = `purchase`. Refreshed on mount, on app-resume, and on
every transaction write (`invalidateTransactionData`). Loading/error fall back to ₹0.
**Note (by design, not a bug):** these totals only count `sale` / `purchase`, not
`payment_in`/`payment_out`/returns standing alone — outstanding is computed off the
sale/purchase document balance, which the payment triggers keep current.

### 2. Recent Transactions query — **[DONE], wired & tappable**
`recentTransactionsProvider`
([transaction_providers.dart](lib/features/transactions/providers/transaction_providers.dart#L286))
lists `sale, purchase, expense, other_income`, newest first, `.take(10)`. The list
renders via `TransactionCard`, and each card's `onTap` calls `_openTransaction`
([dashboard_screen.dart](lib/features/dashboard/screens/dashboard_screen.dart#L292),
wired at [L375](lib/features/dashboard/screens/dashboard_screen.dart#L375)), which routes
by type: `expense` → `/expense`, `other_income` → `/income`, everything else →
`SaleDetailScreen(transactionId:)`. On return it refreshes the recent list and the
To Collect / To Pay totals. (Previously a no-op `onTap: () {}`; now resolved.)

### 3. Salary slip PDF preview — **[DONE], fully wired**
[salary_slip_preview_screen.dart](lib/features/employees/screens/salary_slip_preview_screen.dart)
rasterises the PDF pages via `Printing.raster` and shows them as images (deliberately
**not** `PdfPreview`, which rendered the slip all-black on Android). Three-button row
(WhatsApp / Share PDF / Print) all implemented. Reached from
[salary_payment_screen.dart](lib/features/employees/screens/salary_payment_screen.dart#L135)
after building the PDF with `SalarySlipPdfService.build`.

### 4. Attendance OT panel — **[DONE], fully wired**
[attendance_screen.dart](lib/features/employees/screens/attendance_screen.dart). OT is an
**independent toggle**, not a 4th status: each row has Full/Half/Absent radios plus a
separate OT dot (hidden when Absent). Tapping OT slides in an `AnimatedContainer` side
panel (width 0→160) to enter hours; live pay = `hours × employee.overtimeRate`. Saved per
employee/day via `repo.setAttendance(..., overtimeHours:)`; Absent days force OT to 0.

---

## Stubs / disabled / deferred (intentional, verified)

| Component | Status | Detail |
|---|---|---|
| [google_drive_backup.dart](lib/services/backup/google_drive_backup.dart) | **[STUB]** | Phase-4 **backup** provider (separate from Phase-5 sync). Gated behind `_configured = false`; network methods throw `_DriveNotConfigured` / return empty. Re-enabling is self-contained to this file. |
| [aws_s3_backup.dart](lib/services/backup/aws_s3_backup.dart) | **[STUB]** | Every method throws `UnimplementedError`. Exists so a future S3 swap is a one-line change at the composition root. |
| [cloud_backups_list_screen.dart](lib/features/backup/screens/cloud_backups_list_screen.dart) | **[PARTIAL]** | Lists cloud backups, but the Drive backup provider is deferred so the listing is empty. |
| [usb_printer_service.dart](lib/services/printer/usb_printer_service.dart) | **[STUB]** | Disabled — no maintained `usb_serial` plugin compatible with modern AGP. Reports no devices, refuses to connect, throws on print. BT + network printing unaffected. |

**Local** backup/restore (file copy, share, restore-from-file) in
[backup_manager.dart](lib/services/backup/backup_manager.dart) is **[DONE]** and works
fully offline (WAL-checkpoints before copy; `DatabaseHelper.close/reopen` for restore).

---

## Two-way Google Drive sync (Phase 5) — **[DONE]**

Real, not stubbed. Android↔Windows row-level merge.

- [sync_engine.dart](lib/services/sync/sync_engine.dart) — upload this device's complete
  uuid-keyed snapshot to `<deviceType>_changes.json`, download the other device's file,
  merge row-by-row in dependency order (parents before children, retry loop for deferred
  children), **latest-`updatedAt`-wins** with a `device_id` tiebreak. Never throws —
  returns a `SyncResult` status. Per-record merge errors are logged, not swallowed.
- [drive_service.dart](lib/services/sync/drive_service.dart) — Drive **v3 REST over raw
  `http`** (works on both platforms). Scope `drive.file`. Folder "BusinessPro Sync".
- [auth_service.dart](lib/services/sync/auth_service.dart) — **Android-only** Google
  Sign-In → Drive OAuth token; publishes token to a Firestore relay so Windows keeps
  syncing past the ~1h handoff-token expiry. Windows never constructs the sign-in.
- **Firebase / Firestore** is used **only** for the QR link handoff + token relay, not as
  a data store. Hardcoded web OAuth client id in `auth_service.dart`.
- [sync_scheduler.dart](lib/services/sync/sync_scheduler.dart) — triggers: app resume,
  ~3s debounce after a transaction save, periodic.

---

## Notable "differs from intended design" / gotchas

1. **Navigation is `MaterialApp.routes` + `Navigator.push`/`pushNamed`.** Don't assume
   go_router routing (the unused `go_router` dep has been **removed**).
2. **Riverpod is hand-written, no code-gen.** No `@riverpod`, no `.g.dart`. All
   providers are hand-written (`FutureProvider`, `StateProvider`, `Provider`,
   `.family`). The dead codegen/lint deps (`riverpod_annotation`, `riverpod_generator`,
   `build_runner`, `riverpod_lint`, `custom_lint`) were confirmed unused and **removed**;
   `flutter_riverpod` remains and is load-bearing. **Gotcha:** the app-lock state is the
   one non-Riverpod piece — [app_lock_service.dart](lib/services/security/app_lock_service.dart)
   is a `ChangeNotifier` singleton reached via `AppLockService.instance` and observed
   with a `ListenableBuilder`, not `ref.watch`.
3. **Recent-transactions cards on the dashboard are now tappable** — the card's
   `onTap` calls `_openTransaction`
   ([dashboard_screen.dart](lib/features/dashboard/screens/dashboard_screen.dart#L292)),
   which routes by type: `expense` → `/expense`, `other_income` → `/income`, and
   everything else → `SaleDetailScreen(transactionId:)` (the one generic detail
   screen). On return it refreshes the recent list and the To Collect / To Pay
   totals (was previously a no-op `onTap: () {}`).
4. **Single-business only.** `business_id = 1` is hardcoded across repositories,
   settings, and seed data; there is no business-switching path despite the
   `businesses` table being keyed by id.
5. **Income reuses Expense.** `IncomeListScreen` is `ExpenseListScreen(isIncome: true)` —
   intentional, not a missing screen.
6. **Two separate "Google Drive" features.** Phase-5 **sync** (`services/sync/`,
   fully implemented, REST) vs Phase-4 **backup** (`services/backup/google_drive_backup.dart`,
   stubbed). Easy to confuse — they share a vendor, not code.
7. **FK enforcement is toggled OFF** during a pending v6 upgrade (table rebuild) and
   restored at the end of that migration — see `_onConfigure` notes if touching migrations.
8. **Sync correctness depends on the `is_synced` trigger guards.** Removing/altering the
   stock or payment triggers without preserving `COALESCE(NEW.is_synced,0)=0` will
   double-apply stock and account balances on every sync (this was the v10 fix).
9. **Inserting an "already-synced" row (`is_synced=1`) with a NULL `uuid` silently
   clears the synced flag.** On insert, `trg_sync_uuid_<table>` fires (`WHEN NEW.uuid
   IS NULL`) and issues an AFTER-INSERT `UPDATE` to fill the uuid — which in turn trips
   `trg_sync_dirty_<table>` (`WHEN NEW.is_synced = OLD.is_synced AND OLD.is_synced = 1`),
   flipping `is_synced` back to **0**. Net effect: the row you meant to mark synced is
   marked dirty and re-uploads on the next sync. Real sync-merged rows always arrive
   *with* a uuid (the source device generated it), so this never bites in production —
   but **any new code that inserts a row already considered synced MUST supply a uuid**
   (and the migration tests follow this rule: every `is_synced=1` raw insert sets an
   explicit `uuid`).

---

## Tests

`test/` holds: `widget_test.dart` (placeholder smoke test), `phase3_transactions_test.dart`
(calculation correctness — discount/tax/round-off), and `invoice_pdf_test.dart`.
No broad coverage of repositories, sync, or migrations.
