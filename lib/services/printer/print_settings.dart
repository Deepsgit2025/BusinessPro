/// PrintSettings — the single source of truth for every print decision in the
/// app. Both the thermal ESC/POS formatter and the A4/A5 PDF formatter read
/// every toggle from here; there are no hardcoded print choices anywhere.
///
/// Loaded from the `settings` table via [PrintSettingsRepository]. The defaults
/// below match the values pre-inserted at business initialization, so a freshly
/// set-up business and a never-touched setting behave identically.
class PrintSettings {
  // ── Thermal general ────────────────────────────────────────────────────────
  final bool thermalIsDefault;
  final String paperSize; // 'mm58' | 'mm80'
  final int numberOfCopies;
  final int extraLinesAtEnd;
  final bool autoCutPaper;
  final bool openCashDrawer;
  final bool useTextStyling;

  // ── Regular printer ────────────────────────────────────────────────────────
  final String printTextSize; // 'small' | 'medium' | 'large'
  final String pageSize; // 'A4' | 'A5'
  final String orientation; // 'portrait' | 'landscape'
  final bool repeatHeaderAllPages;
  final bool printOriginalDuplicate;
  final int extraSpacesOnTop;
  final int minRowsInItemTable;

  // ── Header ─────────────────────────────────────────────────────────────────
  final bool printCompanyName;
  final String companyNameTextSize; // 'small' | 'medium' | 'large'
  final bool printLogo;
  final bool printAddress;
  final bool printEmail;
  final bool printPhone;
  final bool printGstin;

  // ── Item table columns ─────────────────────────────────────────────────────
  final bool showSNo;
  final bool showHsn;
  final bool showUnit;
  final bool showMrp;
  final bool showDescription;
  final bool showTotalQuantity;

  // ── Totals section ─────────────────────────────────────────────────────────
  final bool showAmountWithDecimal;
  final bool showReceivedAmount;
  final bool showBalanceAmount;
  final bool showPartyBalance;
  final bool showTaxDetails;
  final bool showAmountGrouping;
  final String amountInWordsFormat; // 'indian' | 'international'
  final bool showYouSaved;

  // ── Footer ─────────────────────────────────────────────────────────────────
  final bool printDescription;
  final bool printTermsConditions;
  final String termsConditionsText;
  final bool printReceivedBy;
  final bool printDeliveredBy;
  final bool printSignatureText;
  final String signatureText;
  final bool printPaymentMode;
  final bool printPageNumbers;
  final bool printAcknowledgement;

  // ── Bill formats (which PDF layout per document type) ───────────────────────
  final String invoiceFormat; // 'format1'
  final String estimateFormat; // 'format2'

  const PrintSettings({
    this.thermalIsDefault = false,
    this.paperSize = 'mm80',
    this.numberOfCopies = 1,
    this.extraLinesAtEnd = 0,
    this.autoCutPaper = false,
    this.openCashDrawer = false,
    this.useTextStyling = true,
    this.printTextSize = 'medium',
    this.pageSize = 'A4',
    this.orientation = 'portrait',
    this.repeatHeaderAllPages = true,
    this.printOriginalDuplicate = false,
    this.extraSpacesOnTop = 0,
    this.minRowsInItemTable = 0,
    this.printCompanyName = true,
    this.companyNameTextSize = 'large',
    this.printLogo = true,
    this.printAddress = true,
    this.printEmail = true,
    this.printPhone = true,
    this.printGstin = true,
    this.showSNo = true,
    this.showHsn = true,
    this.showUnit = true,
    this.showMrp = true,
    this.showDescription = true,
    this.showTotalQuantity = true,
    this.showAmountWithDecimal = true,
    this.showReceivedAmount = true,
    this.showBalanceAmount = true,
    this.showPartyBalance = false,
    this.showTaxDetails = true,
    this.showAmountGrouping = true,
    this.amountInWordsFormat = 'indian',
    this.showYouSaved = true,
    this.printDescription = true,
    this.printTermsConditions = true,
    this.termsConditionsText = 'Thank you for your business!',
    this.printReceivedBy = true,
    this.printDeliveredBy = true,
    this.printSignatureText = true,
    this.signatureText = 'Authorized Signatory',
    this.printPaymentMode = false,
    this.printPageNumbers = true,
    this.printAcknowledgement = false,
    this.invoiceFormat = 'format1',
    this.estimateFormat = 'format2',
  });
}
