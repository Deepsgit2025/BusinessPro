import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/database_helper.dart';
import '../../parties/repositories/party_repository.dart';
import '../models/transaction.dart';
import '../models/transaction_item.dart';

/// Builds a printable A4 PDF for a sale invoice or estimate.
///
/// The document is rendered fresh from the snapshotted transaction data, the
/// business profile, and (when present) the linked party. Bank details and the
/// UPI scan-to-pay QR are gated by the two per-business toggles stored on the
/// `businesses` row (`print_bank_on_invoice`, `print_upi_qr_on_invoice`); the
/// QR additionally requires a non-empty `upi_id`.
///
/// The default PDF font (Helvetica) has no glyph for the rupee sign, so we load
/// the bundled Noto Sans family which does.
class InvoicePdfService {
  InvoicePdfService._();

  static final _dateFmt = DateFormat('dd MMM yyyy');
  // PDF currency: the bundled Noto Sans renders the rupee glyph, so we use a
  // plain Indian-grouped number formatter and prefix the symbol ourselves
  // (NumberFormat.currency would also work, but keeping it explicit lets the
  // caller-facing helper stay symbol-agnostic if the business currency differs).
  static final _amountFmt = NumberFormat('#,##,##0.00', 'en_IN');

  static pw.Font? _regular;
  static pw.Font? _bold;

  /// Loads and caches the Noto Sans fonts from assets. Cheap after first call.
  static Future<void> _ensureFonts() async {
    if (_regular != null && _bold != null) return;
    final reg = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
    _regular = pw.Font.ttf(reg);
    _bold = pw.Font.ttf(bold);
  }

  /// Builds the invoice PDF bytes for [transaction] with its [items].
  /// Fetches the business profile and party internally.
  ///
  /// Pass [docTitleOverride] to force the document heading (e.g. 'DELIVERY
  /// CHALLAN') instead of deriving it from the transaction type. When
  /// [hidePrices] is true the rate / discount / tax / amount columns and the
  /// totals block are suppressed — a delivery challan lists the goods dispatched,
  /// not money owed.
  static Future<Uint8List> build({
    required Transaction transaction,
    required List<TransactionItem> items,
    String? docTitleOverride,
    bool hidePrices = false,
  }) async {
    await _ensureFonts();
    final biz = await DatabaseHelper.getBusiness() ?? const {};
    final party = transaction.partyId != null
        ? await PartyRepository().getById(transaction.partyId!)
        : null;

    final symbol = (biz['currency_symbol'] as String?) ?? '₹';
    String money(num v) => '$symbol${_amountFmt.format(v)}';

    // Set every font slot to a Noto Sans face (and a fallback) so no text ever
    // falls back to the built-in Courier, which has no rupee glyph / Unicode.
    final theme = pw.ThemeData.withFont(
      base: _regular!,
      bold: _bold!,
      italic: _regular!,
      boldItalic: _bold!,
      fontFallback: [_regular!],
    );
    final doc = pw.Document(theme: theme);

    final isEstimate = transaction.transactionType == TxnTypes.estimate;
    final docTitle = docTitleOverride ?? _titleFor(transaction.transactionType);

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) => [
          _header(biz, docTitle, transaction, money),
          pw.SizedBox(height: 16),
          _partySection(biz, party, transaction),
          pw.SizedBox(height: 12),
          _itemsTable(items, money, hidePrices: hidePrices),
          pw.SizedBox(height: 10),
          if (!hidePrices) _totalsAndPayment(transaction, money),
          pw.SizedBox(height: 16),
          // A challan (hidePrices) is treated like an estimate for the footer:
          // no bank / UPI-QR payment block.
          _footer(biz, transaction, isEstimate || hidePrices, money),
        ],
      ),
    );

    return doc.save();
  }

  // ── Header: business identity + invoice meta ──────────────────────────────

  static pw.Widget _header(
    Map<dynamic, dynamic> biz,
    String docTitle,
    Transaction t,
    String Function(num) money,
  ) {
    final bizName = (biz['name'] as String?)?.trim();
    final addressLines = <String>[
      for (final k in ['address_line1', 'address_line2'])
        if (((biz[k] as String?) ?? '').trim().isNotEmpty) (biz[k] as String).trim(),
      [
        (biz['city'] as String?)?.trim(),
        (biz['state'] as String?)?.trim(),
        (biz['pincode'] as String?)?.trim(),
      ].where((s) => s != null && s.isNotEmpty).join(', '),
    ].where((s) => s.trim().isNotEmpty).toList();

    final gstin = ((biz['gstin'] as String?) ?? '').trim();
    final phone = ((biz['phone'] as String?) ?? '').trim();
    final email = ((biz['email'] as String?) ?? '').trim();

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                bizName?.isNotEmpty == true ? bizName! : 'My Business',
                style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 2),
              for (final line in addressLines)
                pw.Text(line, style: const pw.TextStyle(fontSize: 9)),
              if (phone.isNotEmpty || email.isNotEmpty)
                pw.Text(
                  [
                    if (phone.isNotEmpty) 'Ph: $phone',
                    if (email.isNotEmpty) email,
                  ].join('  ·  '),
                  style: const pw.TextStyle(fontSize: 9),
                ),
              if (gstin.isNotEmpty)
                pw.Text('GSTIN: $gstin',
                    style: pw.TextStyle(
                        fontSize: 9, fontWeight: pw.FontWeight.bold)),
            ],
          ),
        ),
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Text(docTitle,
                style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blue800)),
            pw.SizedBox(height: 4),
            _metaRow('No', t.transactionNumber),
            _metaRow('Date', _dateFmt.format(_parseDate(t.transactionDate))),
            if (t.dueDate != null && t.dueDate!.isNotEmpty)
              _metaRow('Due', _dateFmt.format(_parseDate(t.dueDate!))),
          ],
        ),
      ],
    );
  }

  static pw.Widget _metaRow(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 1),
        child: pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Text('$label: ',
                style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            pw.Text(value,
                style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
          ],
        ),
      );

  // ── Bill-to party ─────────────────────────────────────────────────────────

  static pw.Widget _partySection(
    Map<dynamic, dynamic> biz,
    dynamic party,
    Transaction t,
  ) {
    final isPurchase = t.transactionType == TxnTypes.purchase;
    final heading = isPurchase ? 'Bill From' : 'Bill To';

    final name = party?.name as String? ?? t.partyName ?? '';
    final addr = <String>[
      if ((party?.billingAddress as String?)?.trim().isNotEmpty ?? false)
        (party!.billingAddress as String).trim(),
      [
        (party?.billingCity as String?)?.trim(),
        (party?.billingState as String?)?.trim(),
        (party?.billingPincode as String?)?.trim(),
      ].where((s) => s != null && s.isNotEmpty).join(', '),
    ].where((s) => s.trim().isNotEmpty).toList();
    final partyGstin = (party?.gstin as String?)?.trim() ?? '';
    final partyPhone = (party?.phone as String?)?.trim() ?? '';

    return pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.all(8),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(heading,
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
          pw.SizedBox(height: 2),
          pw.Text(name.isEmpty ? '—' : name,
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold)),
          for (final line in addr)
            pw.Text(line, style: const pw.TextStyle(fontSize: 9)),
          if (partyPhone.isNotEmpty)
            pw.Text('Ph: $partyPhone', style: const pw.TextStyle(fontSize: 9)),
          if (partyGstin.isNotEmpty)
            pw.Text('GSTIN: $partyGstin', style: const pw.TextStyle(fontSize: 9)),
        ],
      ),
    );
  }

  // ── Line items table ──────────────────────────────────────────────────────

  static pw.Widget _itemsTable(
    List<TransactionItem> items,
    String Function(num) money, {
    bool hidePrices = false,
  }) {
    final headerStyle = pw.TextStyle(
        fontSize: 9, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
    const cellStyle = pw.TextStyle(fontSize: 9);

    pw.Widget cell(String text,
            {pw.TextStyle style = cellStyle,
            pw.Alignment align = pw.Alignment.centerLeft}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: pw.Text(text, style: style),
        );

    // A delivery challan shows only the goods dispatched (no money columns).
    final anyTax = !hidePrices && items.any((it) => it.taxAmount > 0);
    final anyDiscount = !hidePrices && items.any((it) => it.discountAmount > 0);

    final headers = <pw.Widget>[
      cell('#', style: headerStyle),
      cell('Item', style: headerStyle),
      cell('Qty', style: headerStyle, align: pw.Alignment.centerRight),
      if (!hidePrices)
        cell('Rate', style: headerStyle, align: pw.Alignment.centerRight),
      if (anyDiscount)
        cell('Disc', style: headerStyle, align: pw.Alignment.centerRight),
      if (anyTax)
        cell('Tax', style: headerStyle, align: pw.Alignment.centerRight),
      if (!hidePrices)
        cell('Amount', style: headerStyle, align: pw.Alignment.centerRight),
    ];

    final columnWidths = <int, pw.TableColumnWidth>{
      0: const pw.FixedColumnWidth(20),
      1: const pw.FlexColumnWidth(4),
      2: const pw.FlexColumnWidth(1.4),
    };
    var next = 3;
    if (!hidePrices) columnWidths[next++] = const pw.FlexColumnWidth(1.6);
    if (anyDiscount) columnWidths[next++] = const pw.FlexColumnWidth(1.4);
    if (anyTax) columnWidths[next++] = const pw.FlexColumnWidth(1.4);
    if (!hidePrices) columnWidths[next] = const pw.FlexColumnWidth(1.8);

    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.blue800),
        children: headers,
      ),
    ];

    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      rows.add(pw.TableRow(
        decoration: pw.BoxDecoration(
          color: i.isEven ? PdfColors.white : PdfColors.grey50,
        ),
        children: [
          cell('${i + 1}'),
          cell(
            it.itemName +
                (it.itemHsn != null && it.itemHsn!.isNotEmpty
                    ? '\nHSN: ${it.itemHsn}'
                    : ''),
          ),
          cell(_qty(it.quantity, it.unitName), align: pw.Alignment.centerRight),
          if (!hidePrices)
            cell(money(it.unitPrice), align: pw.Alignment.centerRight),
          if (anyDiscount)
            cell(it.discountAmount > 0 ? '-${money(it.discountAmount)}' : '-',
                align: pw.Alignment.centerRight),
          if (anyTax)
            cell(
                it.taxAmount > 0
                    ? '${money(it.taxAmount)}\n(${_pct(it.taxRate)}%)'
                    : '-',
                align: pw.Alignment.centerRight),
          if (!hidePrices)
            cell(money(it.totalAmount),
                align: pw.Alignment.centerRight,
                style:
                    pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
        ],
      ));
    }

    return pw.Table(
      columnWidths: columnWidths,
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      children: rows,
    );
  }

  // ── Totals + payment status ───────────────────────────────────────────────

  static pw.Widget _totalsAndPayment(Transaction t, String Function(num) money) {
    pw.Widget line(String label, num value,
        {bool bold = false, PdfColor? color}) {
      return pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 1.5),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label,
                style: pw.TextStyle(
                    fontSize: bold ? 11 : 9,
                    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                    color: color)),
            pw.Text(money(value),
                style: pw.TextStyle(
                    fontSize: bold ? 11 : 9,
                    fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                    color: color)),
          ],
        ),
      );
    }

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(child: pw.SizedBox()),
        pw.Container(
          width: 220,
          child: pw.Column(
            children: [
              line('Subtotal', t.subtotal),
              if (t.discountAmount > 0) line('Discount', -t.discountAmount),
              if (t.cgstAmount > 0) line('CGST', t.cgstAmount),
              if (t.sgstAmount > 0) line('SGST', t.sgstAmount),
              if (t.igstAmount > 0) line('IGST', t.igstAmount),
              if (t.roundOff != 0) line('Round Off', t.roundOff),
              pw.Divider(height: 8, color: PdfColors.grey400),
              line('Total', t.totalAmount, bold: true),
              if (t.paidAmount > 0)
                line('Paid', t.paidAmount, color: PdfColors.green800),
              if (t.balanceAmount > 0)
                line('Balance Due', t.balanceAmount,
                    bold: true, color: PdfColors.red800),
            ],
          ),
        ),
      ],
    );
  }

  // ── Footer: bank details, UPI QR, notes, signature ────────────────────────

  static pw.Widget _footer(
    Map<dynamic, dynamic> biz,
    Transaction t,
    bool isEstimate,
    String Function(num) money,
  ) {
    final printBank = ((biz['print_bank_on_invoice'] as int?) ?? 1) == 1;
    final printQr = ((biz['print_upi_qr_on_invoice'] as int?) ?? 1) == 1;
    final upiId = ((biz['upi_id'] as String?) ?? '').trim();
    final bizName = ((biz['name'] as String?) ?? 'My Business').trim();

    final bankName = ((biz['bank_name'] as String?) ?? '').trim();
    final bankAcc = ((biz['bank_account_no'] as String?) ?? '').trim();
    final bankIfsc = ((biz['bank_ifsc'] as String?) ?? '').trim();
    final hasBank = bankName.isNotEmpty || bankAcc.isNotEmpty || bankIfsc.isNotEmpty;

    // Estimates are quotations, not demands for payment, so no QR/bank block.
    final showBank = !isEstimate && printBank && hasBank;
    final showQr = !isEstimate && printQr && upiId.isNotEmpty;

    final widgets = <pw.Widget>[];

    if (showBank || showQr) {
      widgets.add(
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (showBank)
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text('Bank Details',
                        style: pw.TextStyle(
                            fontSize: 10, fontWeight: pw.FontWeight.bold)),
                    pw.SizedBox(height: 2),
                    if (bankName.isNotEmpty)
                      pw.Text('Bank: $bankName',
                          style: const pw.TextStyle(fontSize: 9)),
                    if (bankAcc.isNotEmpty)
                      pw.Text('A/C No: $bankAcc',
                          style: const pw.TextStyle(fontSize: 9)),
                    if (bankIfsc.isNotEmpty)
                      pw.Text('IFSC: $bankIfsc',
                          style: const pw.TextStyle(fontSize: 9)),
                    if (upiId.isNotEmpty)
                      pw.Text('UPI: $upiId',
                          style: const pw.TextStyle(fontSize: 9)),
                  ],
                ),
              ),
            if (showQr)
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.center,
                children: [
                  pw.Text('Scan to Pay',
                      style: pw.TextStyle(
                          fontSize: 9, fontWeight: pw.FontWeight.bold)),
                  pw.SizedBox(height: 4),
                  pw.BarcodeWidget(
                    barcode: pw.Barcode.qrCode(),
                    data: _upiUri(
                      upiId: upiId,
                      payeeName: bizName,
                      amount: t.balanceAmount > 0 ? t.balanceAmount : t.totalAmount,
                      note: t.transactionNumber,
                    ),
                    width: 90,
                    height: 90,
                    // Never print the raw upi:// URI under the QR (it would also
                    // fall back to Courier, which lacks Unicode support).
                    drawText: false,
                  ),
                  pw.SizedBox(height: 2),
                  pw.Text(
                    money(t.balanceAmount > 0 ? t.balanceAmount : t.totalAmount),
                    style: pw.TextStyle(
                        fontSize: 9, fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
          ],
        ),
      );
    }

    final notes = (t.notes ?? '').trim();
    final terms = (t.termsConditions ?? '').trim();
    if (notes.isNotEmpty || terms.isNotEmpty) {
      widgets.add(pw.SizedBox(height: 12));
      if (notes.isNotEmpty) {
        widgets.add(pw.Text('Notes: $notes',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey800)));
      }
      if (terms.isNotEmpty) {
        widgets.add(pw.Text('Terms: $terms',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey800)));
      }
    }

    widgets.add(pw.SizedBox(height: 20));
    widgets.add(
      pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.end,
        children: [
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text('For $bizName',
                  style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 28),
              pw.Text('Authorised Signatory',
                  style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            ],
          ),
        ],
      ),
    );

    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: widgets,
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Standard UPI deep link. UPI apps read the embedded payee + amount and
  /// pre-fill the payment; the customer only confirms.
  static String _upiUri({
    required String upiId,
    required String payeeName,
    required double amount,
    required String note,
  }) {
    final params = {
      'pa': upiId,
      'pn': payeeName,
      'am': amount.toStringAsFixed(2),
      'cu': 'INR',
      'tn': note,
    };
    final query = params.entries
        .map((e) =>
            '${e.key}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'upi://pay?$query';
  }

  /// The default document heading for a given transaction type.
  static String _titleFor(String type) => switch (type) {
        TxnTypes.estimate => 'ESTIMATE',
        TxnTypes.deliveryChallan => 'DELIVERY CHALLAN',
        TxnTypes.saleReturn => 'CREDIT NOTE',
        TxnTypes.purchaseReturn => 'DEBIT NOTE',
        TxnTypes.saleOrder => 'SALE ORDER',
        TxnTypes.purchase => 'PURCHASE BILL',
        TxnTypes.paymentIn => 'PAYMENT RECEIPT',
        TxnTypes.paymentOut => 'PAYMENT VOUCHER',
        _ => 'TAX INVOICE',
      };

  static DateTime _parseDate(String raw) =>
      DateTime.tryParse(raw) ?? DateTime.now();

  static String _qty(double v, String? unit) {
    final n = v == v.roundToDouble() ? v.toInt().toString() : v.toString();
    return unit == null || unit.isEmpty ? n : '$n $unit';
  }

  static String _pct(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}
