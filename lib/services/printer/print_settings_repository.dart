import 'package:sqflite/sqflite.dart';

import '../../core/constants/app_strings.dart';
import '../../core/database/database_helper.dart';
import 'print_settings.dart';

/// Reads and writes the `print_*` keys in the `settings` table and assembles
/// them into a [PrintSettings]. This is the only place that knows the
/// key → field mapping; the keys themselves live in [AppStrings].
class PrintSettingsRepository {
  /// Load all print settings for [businessId] in a single query.
  Future<PrintSettings> load(int businessId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'settings',
      where: 'business_id = ? AND key LIKE ?',
      whereArgs: [businessId, 'print_%'],
    );
    final map = {
      for (final r in rows) r['key'] as String: (r['value'] as String?) ?? '',
    };

    bool b(String key, bool def) => (map[key] ?? (def ? '1' : '0')) == '1';
    String s(String key, String def) =>
        (map[key]?.isNotEmpty ?? false) ? map[key]! : def;
    int i(String key, int def) => int.tryParse(map[key] ?? '') ?? def;

    return PrintSettings(
      thermalIsDefault: b(AppStrings.kPrintThermalDefault, false),
      paperSize: s(AppStrings.kPrintPaperSize, 'mm80'),
      numberOfCopies: i(AppStrings.kPrintCopies, 1),
      extraLinesAtEnd: i(AppStrings.kPrintExtraLines, 0),
      autoCutPaper: b(AppStrings.kPrintAutoCut, false),
      openCashDrawer: b(AppStrings.kPrintCashDrawer, false),
      useTextStyling: b(AppStrings.kPrintTextStyling, true),
      printTextSize: s(AppStrings.kPrintRegularTextSize, 'medium'),
      pageSize: s(AppStrings.kPrintPageSize, 'A4'),
      orientation: s(AppStrings.kPrintOrientation, 'portrait'),
      repeatHeaderAllPages: b(AppStrings.kPrintRepeatHeader, true),
      printOriginalDuplicate: b(AppStrings.kPrintOriginalDuplicate, false),
      extraSpacesOnTop: i(AppStrings.kPrintExtraTopSpace, 0),
      minRowsInItemTable: i(AppStrings.kPrintMinItemRows, 0),
      printCompanyName: b(AppStrings.kPrintCompanyName, true),
      companyNameTextSize: s(AppStrings.kPrintCompanyNameSize, 'large'),
      printLogo: b(AppStrings.kPrintLogo, true),
      printAddress: b(AppStrings.kPrintAddress, true),
      printEmail: b(AppStrings.kPrintEmail, true),
      printPhone: b(AppStrings.kPrintPhone, true),
      printGstin: b(AppStrings.kPrintGstin, true),
      showSNo: b(AppStrings.kPrintShowSno, true),
      showHsn: b(AppStrings.kPrintShowHsn, true),
      showUnit: b(AppStrings.kPrintShowUnit, true),
      showMrp: b(AppStrings.kPrintShowMrp, true),
      showDescription: b(AppStrings.kPrintShowDescription, true),
      showTotalQuantity: b(AppStrings.kPrintShowTotalQty, true),
      showAmountWithDecimal: b(AppStrings.kPrintAmountDecimal, true),
      showReceivedAmount: b(AppStrings.kPrintReceivedAmount, true),
      showBalanceAmount: b(AppStrings.kPrintBalanceAmount, true),
      showPartyBalance: b(AppStrings.kPrintPartyBalance, false),
      showTaxDetails: b(AppStrings.kPrintTaxDetails, true),
      showAmountGrouping: b(AppStrings.kPrintAmountGrouping, true),
      amountInWordsFormat: s(AppStrings.kPrintAmountWordsFormat, 'indian'),
      showYouSaved: b(AppStrings.kPrintYouSaved, true),
      printDescription: b(AppStrings.kPrintDescription, true),
      printTermsConditions: b(AppStrings.kPrintTerms, true),
      termsConditionsText:
          s(AppStrings.kPrintTermsText, 'Thank you for your business!'),
      printReceivedBy: b(AppStrings.kPrintReceivedBy, true),
      printDeliveredBy: b(AppStrings.kPrintDeliveredBy, true),
      printSignatureText: b(AppStrings.kPrintSignature, true),
      signatureText: s(AppStrings.kPrintSignatureText, 'Authorized Signatory'),
      printPaymentMode: b(AppStrings.kPrintPaymentMode, false),
      printPageNumbers: b(AppStrings.kPrintPageNumbers, true),
      printAcknowledgement: b(AppStrings.kPrintAcknowledgement, false),
      invoiceFormat: s('print_invoice_format', 'format1'),
      estimateFormat: s('print_estimate_format', 'format2'),
    );
  }

  /// Write a single setting (replace existing). Used by the settings screen for
  /// `print_*` keys and by [PrinterManager] for `default_printer_*` keys.
  Future<void> save(int businessId, String key, String value) async {
    final db = await DatabaseHelper.database;
    await db.insert(
      'settings',
      {'business_id': businessId, 'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Read a single string setting, or null if absent. Used for the
  /// `default_printer_*` keys when reconnecting.
  Future<String?> getString(int businessId, String key) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'settings',
      where: 'business_id = ? AND key = ?',
      whereArgs: [businessId, key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }
}
