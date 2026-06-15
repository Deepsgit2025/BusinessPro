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
  static const drawerInventory = 'Inventory';
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

  // ── WhatsApp invoice sharing ───────────────────────────────────────────────
  // '1' ⇒ show the WhatsApp share sheet automatically after a sale is saved.
  static const kWhatsappAutoPrompt = 'whatsapp_auto_prompt';
  // '1' ⇒ the "Send to My WhatsApp" action is offered (owner copy).
  static const kWhatsappOwnerSend = 'whatsapp_owner_send';
  // '1' ⇒ default the "Send to Customer" action on (still opt-in per send).
  static const kWhatsappCustomerSend = 'whatsapp_customer_send';

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
  // The paired Android device id (stored on Windows at link time) — used to read
  // the Firestore token-relay doc so Windows can refresh without re-linking.
  static const kPairedAndroidDeviceId = 'paired_android_device_id';

  // ── Printer phase ───────────────────────────────────────────────────────────
  // PrintSettings is the single source of truth for every print decision. All 45
  // print_* keys are pre-inserted at business init with ConflictAlgorithm.ignore
  // so the future Settings phase needs no migration and user choices are never
  // overwritten on app update. Keys mirror PrintSettings fields 1:1.

  // Thermal general
  static const kPrintThermalDefault = 'print_thermal_default';
  static const kPrintPaperSize = 'print_paper_size'; // 'mm58' | 'mm80'
  static const kPrintCopies = 'print_copies';
  static const kPrintExtraLines = 'print_extra_lines';
  static const kPrintAutoCut = 'print_auto_cut';
  static const kPrintCashDrawer = 'print_cash_drawer';
  static const kPrintTextStyling = 'print_text_styling';

  // Regular printer
  static const kPrintRegularTextSize = 'print_regular_text_size'; // small|medium|large
  static const kPrintPageSize = 'print_page_size'; // 'A4' | 'A5'
  static const kPrintOrientation = 'print_orientation'; // portrait|landscape
  static const kPrintRepeatHeader = 'print_repeat_header';
  static const kPrintOriginalDuplicate = 'print_original_duplicate';
  static const kPrintExtraTopSpace = 'print_extra_top_space';
  static const kPrintMinItemRows = 'print_min_item_rows';

  // Header
  static const kPrintCompanyName = 'print_company_name';
  static const kPrintCompanyNameSize = 'print_company_name_size';
  static const kPrintLogo = 'print_logo';
  static const kPrintAddress = 'print_address';
  static const kPrintEmail = 'print_email';
  static const kPrintPhone = 'print_phone';
  static const kPrintGstin = 'print_gstin';

  // Item table columns
  static const kPrintShowSno = 'print_show_sno';
  static const kPrintShowHsn = 'print_show_hsn';
  static const kPrintShowUnit = 'print_show_unit';
  static const kPrintShowMrp = 'print_show_mrp';
  static const kPrintShowDescription = 'print_show_description';
  static const kPrintShowTotalQty = 'print_show_total_qty';

  // Totals section
  static const kPrintAmountDecimal = 'print_amount_decimal';
  static const kPrintReceivedAmount = 'print_received_amount';
  static const kPrintBalanceAmount = 'print_balance_amount';
  static const kPrintPartyBalance = 'print_party_balance';
  static const kPrintTaxDetails = 'print_tax_details';
  static const kPrintAmountGrouping = 'print_amount_grouping';
  static const kPrintAmountWordsFormat = 'print_amount_words_format'; // indian|international
  static const kPrintYouSaved = 'print_you_saved';

  // Footer
  static const kPrintDescription = 'print_description';
  static const kPrintTerms = 'print_terms';
  static const kPrintTermsText = 'print_terms_text';
  static const kPrintReceivedBy = 'print_received_by';
  static const kPrintDeliveredBy = 'print_delivered_by';
  static const kPrintSignature = 'print_signature';
  static const kPrintSignatureText = 'print_signature_text';
  static const kPrintPaymentMode = 'print_payment_mode';
  static const kPrintPageNumbers = 'print_page_numbers';
  static const kPrintAcknowledgement = 'print_acknowledgement';

  // Saved default printer (not part of PrintSettings; persisted by PrinterManager)
  static const kDefaultPrinterId = 'default_printer_id';
  static const kDefaultPrinterName = 'default_printer_name';
  static const kDefaultPrinterType = 'default_printer_type';
  static const kDefaultPrinterAddress = 'default_printer_address';
  // JSON array of manually-added network printers.
  static const kSavedNetworkPrinters = 'saved_network_printers';
}
