import 'dart:typed_data';

import '../../features/parties/models/party.dart';
import '../../features/transactions/models/transaction.dart';
import '../../features/transactions/models/transaction_item.dart';
import 'esc_pos_builder.dart';
import 'print_settings.dart';

/// Formats transactions into ESC/POS byte streams for thermal printers. Every
/// section is gated on [PrintSettings] — there are no hardcoded print decisions
/// here. `business` is the raw `businesses` row map (the app stores it as a Map,
/// not a typed model); `party` is the optional typed [Party].
class ThermalInvoiceFormatter {
  Uint8List formatSaleInvoice({
    required Transaction transaction,
    required List<TransactionItem> items,
    required Map<String, dynamic> business,
    required PrintSettings settings,
    Party? party,
    String? paymentModeName,
  }) {
    final b = EscPosBuilder(paperSize: _paper(settings)).init();
    final t = transaction;

    // ── Header ────────────────────────────────────────────────────────────────
    b.alignCenter();
    if (settings.printCompanyName) {
      final name = (business['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) {
        if (settings.useTextStyling) {
          settings.companyNameTextSize == 'large' ? b.fontDouble() : b.fontBold();
        }
        b.textLine(name.toUpperCase());
        if (settings.useTextStyling) b.fontNormal();
      }
    }
    if (settings.printAddress) {
      _line(b, business['address_line1']);
      _line(b, business['address_line2']);
      final cityLine = [
        business['city'],
        business['state'],
        business['pincode'],
      ].where((e) => (e as String?)?.trim().isNotEmpty ?? false).join(', ');
      if (cityLine.isNotEmpty) b.textLine(cityLine);
    }
    if (settings.printPhone) _line(b, business['phone'], prefix: 'Ph: ');
    if (settings.printEmail) _line(b, business['email']);
    if (settings.printGstin) _line(b, business['gstin'], prefix: 'GSTIN: ');

    b.emptyLine().doubleDivider();

    // ── Document info ─────────────────────────────────────────────────────────
    b.alignLeft();
    if (settings.useTextStyling) b.fontBold();
    b.textLine(_docTitle(t.transactionType));
    if (settings.useTextStyling) b.fontNormal();
    b.row('No: ${t.transactionNumber}', 'Date: ${_date(t.transactionDate)}');
    if (t.dueDate != null && t.dueDate!.isNotEmpty) {
      b.row('Due:', _date(t.dueDate!));
    }

    // ── Party ─────────────────────────────────────────────────────────────────
    if (party != null) {
      b.divider();
      if (settings.useTextStyling) b.fontBold();
      b.textLine('Bill To:');
      if (settings.useTextStyling) b.fontNormal();
      b.textLine(party.name);
      if (party.phone != null && party.phone!.isNotEmpty) {
        b.textLine('Ph: ${party.phone}');
      }
      if (settings.printGstin && (party.gstin?.isNotEmpty ?? false)) {
        b.textLine('GSTIN: ${party.gstin}');
      }
      if (party.billingAddress != null && party.billingAddress!.isNotEmpty) {
        b.textLine(party.billingAddress!);
      }
    }

    // ── Items ─────────────────────────────────────────────────────────────────
    b.divider();
    if (settings.useTextStyling) b.fontBold();
    b.row('Item', 'Amt');
    if (settings.useTextStyling) b.fontNormal();
    b.divider();

    var sNo = 1;
    for (final item in items) {
      final namePrefix = settings.showSNo ? '${sNo++}. ' : '';
      final name = '$namePrefix${item.itemName}';

      final qty = StringBuffer(_qty(item.quantity));
      if (settings.showUnit && (item.unitName?.isNotEmpty ?? false)) {
        qty.write(' ${item.unitName}');
      }
      qty.write(' x ${_amt(item.unitPrice, settings)}');
      if (settings.showMrp && item.mrp > 0) {
        qty.write(' MRP:${_amt(item.mrp, settings)}');
      }

      b.itemRow(name, qty.toString(), _amt(item.totalAmount, settings));

      if (settings.showHsn && (item.itemHsn?.isNotEmpty ?? false)) {
        b.textLine('  HSN: ${item.itemHsn}');
      }
      if (settings.showDescription && (item.notes?.isNotEmpty ?? false)) {
        b.textLine('  ${item.notes}');
      }
    }
    for (var i = items.length; i < settings.minRowsInItemTable; i++) {
      b.emptyLine();
    }

    // ── Totals ────────────────────────────────────────────────────────────────
    b.divider();
    if (settings.showTotalQuantity) {
      final totalQty = items.fold<double>(0, (s, i) => s + i.quantity);
      b.row('Total Qty:', _qty(totalQty));
    }
    if (t.discountAmount > 0) {
      b.row('Subtotal:', _amt(t.subtotal, settings));
      b.row('Discount (-):', _amt(t.discountAmount, settings));
    }
    if (settings.showTaxDetails && t.taxAmount > 0) {
      b.row('Taxable:', _amt(t.taxableAmount, settings));
      if (t.cgstAmount > 0) {
        b.row('CGST:', _amt(t.cgstAmount, settings));
        b.row('SGST:', _amt(t.sgstAmount, settings));
      } else if (t.igstAmount > 0) {
        b.row('IGST:', _amt(t.igstAmount, settings));
      }
    }
    if (t.roundOff != 0) b.row('Round Off:', _amt(t.roundOff, settings));

    b.doubleDivider();
    if (settings.useTextStyling) b.fontBold();
    b.row('TOTAL:', _amt(t.totalAmount, settings));
    if (settings.useTextStyling) b.fontNormal();
    b.divider();

    if (settings.showReceivedAmount && t.paidAmount > 0) {
      b.row('Received:', _amt(t.paidAmount, settings));
    }
    if (settings.showBalanceAmount && t.balanceAmount > 0) {
      b.row('Balance Due:', _amt(t.balanceAmount, settings));
    }
    if (settings.showYouSaved && t.discountAmount > 0) {
      b.row('You Saved:', _amt(t.discountAmount, settings));
    }
    if (settings.printPaymentMode &&
        paymentModeName != null &&
        paymentModeName.isNotEmpty) {
      b.row('Payment:', paymentModeName);
    }
    if (settings.showPartyBalance && party != null) {
      final bal = party.toCollect - party.toPay;
      if (bal != 0) b.row('Party Balance:', _amt(bal.abs(), settings));
    }

    // ── Payment details (business bank / UPI) ─────────────────────────────────
    final upi = (business['upi_id'] as String?)?.trim();
    final acc = (business['bank_account_no'] as String?)?.trim();
    if ((upi?.isNotEmpty ?? false) || (acc?.isNotEmpty ?? false)) {
      b.divider();
      if (upi?.isNotEmpty ?? false) b.row('UPI:', upi!);
      if (acc?.isNotEmpty ?? false) {
        b.row('A/C:', acc!);
        final ifsc = (business['bank_ifsc'] as String?)?.trim();
        if (ifsc?.isNotEmpty ?? false) b.row('IFSC:', ifsc!);
      }
    }

    // ── Footer ────────────────────────────────────────────────────────────────
    if (settings.printTermsConditions &&
        settings.termsConditionsText.isNotEmpty) {
      b.divider().textLine(settings.termsConditionsText);
    }
    if (settings.printDescription && (t.notes?.isNotEmpty ?? false)) {
      b.divider().textLine('Note: ${t.notes}');
    }
    if (settings.printReceivedBy) {
      b.emptyLine().row('Received by:', '________________');
    }
    if (settings.printDeliveredBy) {
      b.row('Delivered by:', '________________');
    }
    if (settings.printSignatureText) {
      b.emptyLine().alignCenter().textLine(settings.signatureText);
      final name = (business['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) b.textLine('for $name');
    }
    if (settings.printAcknowledgement) {
      b.emptyLine().alignCenter().textLine('ACKNOWLEDGEMENT COPY');
    }
    b.emptyLine().alignCenter().textLine('Powered by BusinessPro');
    b.emptyLine(settings.extraLinesAtEnd + 2);
    if (settings.autoCutPaper) b.cut();

    return _copies(b.build(), settings.numberOfCopies);
  }

  /// Expense / income receipt.
  Uint8List formatExpenseReceipt({
    required Transaction transaction,
    required Map<String, dynamic> business,
    required PrintSettings settings,
  }) {
    final b = EscPosBuilder(paperSize: _paper(settings)).init();
    final t = transaction;

    b.alignCenter();
    if (settings.printCompanyName) {
      final name = (business['name'] as String?)?.trim();
      if (name != null && name.isNotEmpty) {
        if (settings.useTextStyling) b.fontDouble();
        b.textLine(name.toUpperCase());
        if (settings.useTextStyling) b.fontNormal();
      }
    }
    b.emptyLine();
    if (settings.useTextStyling) b.fontBold();
    b.textLine(t.transactionType == TxnTypes.otherIncome
        ? 'INCOME RECEIPT'
        : 'EXPENSE RECEIPT');
    if (settings.useTextStyling) b.fontNormal();
    b.divider().alignLeft();
    b.row('Date:', _date(t.transactionDate));
    b.row('Ref:', t.transactionNumber);
    b.divider();
    if (t.categoryName != null && t.categoryName!.isNotEmpty) {
      b.row('Category:', t.categoryName!);
    }
    if (settings.useTextStyling) b.fontBold();
    b.row('Amount:', _amt(t.totalAmount, settings));
    if (settings.useTextStyling) b.fontNormal();
    if (settings.printDescription && (t.notes?.isNotEmpty ?? false)) {
      b.textLine('Note: ${t.notes}');
    }
    if (settings.printTermsConditions &&
        settings.termsConditionsText.isNotEmpty) {
      b.divider().textLine(settings.termsConditionsText);
    }
    b.emptyLine().alignCenter().textLine('Powered by BusinessPro');
    b.emptyLine(settings.extraLinesAtEnd + 2);
    if (settings.autoCutPaper) b.cut();

    return _copies(b.build(), settings.numberOfCopies);
  }

  /// A self-contained test receipt, printable without any real transaction.
  Uint8List formatTestPrint(Map<String, dynamic> business, PaperSize paperSize) {
    final b = EscPosBuilder(paperSize: paperSize).init();
    b.alignCenter().doubleDivider();
    b.fontDouble().textLine('BUSINESSPRO').fontNormal();
    b.textLine('TEST PRINT').doubleDivider().alignLeft();
    b.textLine('Printer connected successfully!');
    b.textLine('Paper: ${paperSize == PaperSize.mm58 ? "58mm" : "80mm"}');
    final name = (business['name'] as String?)?.trim();
    b.textLine('Business: ${name?.isNotEmpty == true ? name : "-"}');
    b.textLine('Date: ${_date(DateTime.now().toIso8601String())}');
    b.divider().alignCenter().textLine('Powered by BusinessPro');
    b.emptyLine(3).cut();
    return b.build();
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  PaperSize _paper(PrintSettings s) =>
      s.paperSize == 'mm58' ? PaperSize.mm58 : PaperSize.mm80;

  void _line(EscPosBuilder b, Object? value, {String prefix = ''}) {
    final v = (value as String?)?.trim();
    if (v != null && v.isNotEmpty) b.textLine('$prefix$v');
  }

  Uint8List _copies(Uint8List single, int copies) {
    if (copies <= 1) return single;
    final all = <int>[];
    for (var i = 0; i < copies; i++) {
      all.addAll(single);
    }
    return Uint8List.fromList(all);
  }

  String _docTitle(String type) {
    switch (type) {
      case TxnTypes.sale:
        return 'TAX INVOICE';
      case TxnTypes.purchase:
        return 'PURCHASE BILL';
      case TxnTypes.estimate:
        return 'QUOTATION';
      case TxnTypes.saleReturn:
        return 'CREDIT NOTE';
      case TxnTypes.purchaseReturn:
        return 'DEBIT NOTE';
      case TxnTypes.deliveryChallan:
        return 'DELIVERY CHALLAN';
      case TxnTypes.saleOrder:
      case TxnTypes.purchaseOrder:
        return 'ORDER';
      case TxnTypes.paymentIn:
      case TxnTypes.paymentOut:
        return 'PAYMENT RECEIPT';
      default:
        return 'RECEIPT';
    }
  }

  String _date(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    return '$dd/$mm/${d.year}';
  }

  String _amt(double amount, PrintSettings settings) =>
      settings.showAmountWithDecimal
          ? amount.toStringAsFixed(2)
          : amount.round().toString();

  String _qty(double qty) =>
      qty == qty.truncateToDouble() ? qty.toInt().toString() : qty.toString();
}
