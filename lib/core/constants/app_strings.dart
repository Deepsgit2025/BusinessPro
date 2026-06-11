class AppStrings {
  AppStrings._();

  static const appName = 'BusinessPro';

  // Nav labels
  static const navDashboard = 'Home';
  static const navSale = 'Sale';
  static const navPurchase = 'Purchase';
  static const navParties = 'Parties';
  static const navMore = 'More';

  // Drawer items
  static const drawerItems = 'Items';
  static const drawerExpense = 'Expense';
  static const drawerIncome = 'Income';
  static const drawerCashBank = 'Cash & Bank';
  static const drawerEmployees = 'Employees';
  static const drawerReports = 'Reports';
  static const drawerBackup = 'Backup';
  static const drawerSync = 'Sync & Devices';
  static const drawerSettings = 'Settings';
  static const drawerCompanyProfile = 'Company Profile';

  // Common
  static const save = 'Save';
  static const cancel = 'Cancel';
  static const edit = 'Edit';
  static const delete = 'Delete';
  static const search = 'Search';
  static const add = 'Add';
  static const noData = 'No data found';

  // Settings keys
  static const kDateFormat = 'date_format';
  static const kDecimalPlaces = 'decimal_places';
  static const kTaxEnabled = 'tax_enabled';
  static const kStockTracking = 'stock_tracking';
  static const kLowStockAlert = 'low_stock_alert';
  static const kTheme = 'theme';
  static const kInvoiceTemplate = 'invoice_template';
  static const kShowDiscount = 'show_discount';
  static const kDefaultPaymentMode = 'default_payment_mode';
  static const kBackupReminderDays = 'backup_reminder_days';
  static const kCompanySetupDone = 'company_setup_done';
  // Default transaction-share format: 'image' or 'pdf'. Empty ⇒ ask each time.
  static const kDefaultShareFormat = 'default_share_format';

  // ── Notifications ──────────────────────────────────────────────────────────
  // Master switch + per-type toggles (all default on).
  static const kNotifEnabled = 'notif_enabled';
  static const kNotifMonthEndExpense = 'notif_month_end_expense';
  static const kNotifBackupReminder = 'notif_backup_reminder';
  static const kNotifLowStock = 'notif_low_stock';
  // Tracks the last expense-month the user dismissed, so a dismissed
  // month-end reminder does not re-appear. Stored as 'yyyy-MM'.
  static const kMonthEndExpenseDismissed = 'month_end_expense_dismissed';
  // ISO date of the last successful backup, used by the backup reminder.
  static const kLastBackupAt = 'last_backup_at';

  // ── Phase 5: Google Drive sync ──────────────────────────────────────────────
  // This device's stable sync id (also read by the DB insert triggers).
  static const kSyncDeviceId = 'sync_device_id';
  // Cached Google account email shown in the sync settings screen (Android).
  static const kSyncAccountEmail = 'sync_account_email';
  // Drive OAuth access token + its expiry (ISO-8601). On Android these come from
  // Google Sign-In; on Windows they arrive via the QR handoff.
  static const kDriveAccessToken = 'drive_access_token';
  static const kDriveTokenExpiry = 'drive_token_expiry';
}
