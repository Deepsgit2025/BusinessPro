import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/database_helper.dart';
import '../../../core/utils/amount_to_words.dart';
import '../../../services/printer/print_settings.dart';
import '../../../services/printer/print_settings_repository.dart';
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
  // Used when the "show amount with decimal" print setting is off.
  static final _amountFmtNoDecimal = NumberFormat('#,##,##0', 'en_IN');

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

  /// Loads an image from a stored file path, or null when the path is empty,
  /// missing, or unreadable (corrupt/unsupported) — so a bad logo/signature
  /// never fails the whole PDF.
  static Future<pw.MemoryImage?> _loadImage(String? path) async {
    final p = path?.trim();
    if (p == null || p.isEmpty) return null;
    final f = File(p);
    if (!await f.exists()) return null;
    try {
      return pw.MemoryImage(await f.readAsBytes());
    } catch (_) {
      return null;
    }
  }

  /// Builds the invoice PDF bytes for [transaction] with its [items].
  /// Fetches the business profile and party internally.
  ///
  /// Pass [docTitleOverride] to force the document heading (e.g. 'DELIVERY
  /// CHALLAN') instead of deriving it from the transaction type. When
  /// [hidePrices] is true the rate / discount / tax / amount columns and the
  /// totals block are suppressed — a delivery challan lists the goods dispatched,
  /// not money owed.
  /// The three print copies of a sale invoice (Invoice Format 1), in order.
  static const copyLabels = <String>[
    'ORIGINAL FOR RECIPIENT',
    'DUPLICATE FOR TRANSPORTER',
    'OFFICE COPY',
  ];

  static Future<Uint8List> build({
    required Transaction transaction,
    required List<TransactionItem> items,
    String? docTitleOverride,
    bool hidePrices = false,
    PrintSettings? settings,
    String? copyLabel,
  }) async {
    await _ensureFonts();
    // PrintSettings is the single source of truth for both formatters. Load the
    // saved settings when the caller didn't supply them, so existing callers
    // keep working unchanged.
    final s = settings ?? await PrintSettingsRepository().load(1);
    final biz = await DatabaseHelper.getBusiness() ?? const {};
    final party = transaction.partyId != null
        ? await PartyRepository().getById(transaction.partyId!)
        : null;

    final symbol = (biz['currency_symbol'] as String?) ?? '₹';
    // Honour the decimal toggle: with decimals off, round to whole units.
    final amountFmt = s.showAmountWithDecimal ? _amountFmt : _amountFmtNoDecimal;
    String money(num v) => '$symbol${amountFmt.format(v)}';

    // Business logo + signature, if set and the files still exist.
    final logo = await _loadImage(biz['logo_path'] as String?);
    final signature = await _loadImage(biz['signature_path'] as String?);

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

    final pageFormat = s.pageSize == 'A5' ? PdfPageFormat.a5 : PdfPageFormat.a4;

    doc.addPage(
      pw.MultiPage(
        pageTheme: pw.PageTheme(
          pageFormat: pageFormat,
          theme: theme,
          margin: const pw.EdgeInsets.all(28),
          // Paint the whole page white. Without this the PDF background is
          // transparent, which dark-mode PDF viewers and the shared PNG raster
          // render as black (the logo/photo then blends into the dark).
          buildBackground: (context) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Container(color: PdfColors.white),
          ),
        ),
        build: (context) => _pageContent(
          biz: biz,
          party: party,
          transaction: transaction,
          items: items,
          money: money,
          logo: logo,
          signature: signature,
          s: s,
          docTitleOverride: docTitleOverride,
          hidePrices: hidePrices,
          copyLabel: copyLabel,
        ),
      ),
    );

    return doc.save();
  }

  /// Builds a single PDF containing all three sale-invoice copies (Format 1):
  /// ORIGINAL FOR RECIPIENT, DUPLICATE FOR TRANSPORTER, OFFICE COPY — one page
  /// each, the copy label in the top-right corner. Used for printing only;
  /// sharing always sends the single Original copy via [build].
  ///
  /// [labels] selects which copies to include (defaults to all three), letting
  /// the print sheet honour the user's copy checkboxes.
  static Future<Uint8List> buildAllCopies({
    required Transaction transaction,
    required List<TransactionItem> items,
    PrintSettings? settings,
    List<String>? labels,
  }) async {
    await _ensureFonts();
    final s = settings ?? await PrintSettingsRepository().load(1);
    final biz = await DatabaseHelper.getBusiness() ?? const {};
    final party = transaction.partyId != null
        ? await PartyRepository().getById(transaction.partyId!)
        : null;

    final symbol = (biz['currency_symbol'] as String?) ?? '₹';
    final amountFmt = s.showAmountWithDecimal ? _amountFmt : _amountFmtNoDecimal;
    String money(num v) => '$symbol${amountFmt.format(v)}';

    final logo = await _loadImage(biz['logo_path'] as String?);
    final signature = await _loadImage(biz['signature_path'] as String?);

    final theme = pw.ThemeData.withFont(
      base: _regular!,
      bold: _bold!,
      italic: _regular!,
      boldItalic: _bold!,
      fontFallback: [_regular!],
    );
    final doc = pw.Document(theme: theme);
    final pageFormat = s.pageSize == 'A5' ? PdfPageFormat.a5 : PdfPageFormat.a4;
    final selected = labels == null || labels.isEmpty ? copyLabels : labels;

    for (final label in selected) {
      doc.addPage(
        pw.MultiPage(
          pageTheme: pw.PageTheme(
            pageFormat: pageFormat,
            theme: theme,
            margin: const pw.EdgeInsets.all(28),
            buildBackground: (context) => pw.FullPage(
              ignoreMargins: true,
              child: pw.Container(color: PdfColors.white),
            ),
          ),
          build: (context) => _pageContent(
            biz: biz,
            party: party,
            transaction: transaction,
            items: items,
            money: money,
            logo: logo,
            signature: signature,
            s: s,
            copyLabel: label,
          ),
        ),
      );
    }

    return doc.save();
  }

  /// The page body, shared by [build] (one page) and [buildAllCopies] (three).
  static List<pw.Widget> _pageContent({
    required Map<dynamic, dynamic> biz,
    required dynamic party,
    required Transaction transaction,
    required List<TransactionItem> items,
    required String Function(num) money,
    required pw.MemoryImage? logo,
    required pw.MemoryImage? signature,
    required PrintSettings s,
    String? docTitleOverride,
    bool hidePrices = false,
    String? copyLabel,
  }) {
    final isEstimate = transaction.transactionType == TxnTypes.estimate;
    final isSale = transaction.transactionType == TxnTypes.sale;
    final docTitle = docTitleOverride ?? _titleFor(transaction.transactionType);

    // Sale invoices use the exact bordered Format 1 layout (screenshot match).
    // Challans (hidePrices) and every other doc type keep the existing layout.
    if (isSale && !hidePrices) {
      return _format1Page(
        biz: biz,
        party: party,
        t: transaction,
        items: items,
        money: money,
        logo: logo,
        signature: signature,
        s: s,
        copyLabel: copyLabel ?? copyLabels.first,
      );
    }

    // Estimates use the exact bordered Format 2 layout (screenshot match).
    if (isEstimate && !hidePrices) {
      return _format2Page(
        biz: biz,
        party: party,
        t: transaction,
        items: items,
        money: money,
        logo: logo,
        signature: signature,
        s: s,
      );
    }

    return [
      _header(biz, docTitle, transaction, money, logo, s,
          copyLabel: copyLabel, isEstimate: isEstimate),
      // Transport & delivery grid (Format 1, sale invoices only).
      if (isSale) _transportGrid(transaction),
      pw.SizedBox(height: 16),
      _partySection(biz, party, transaction, s, isEstimate: isEstimate),
      pw.SizedBox(height: 12),
      // Estimate Format 2 shows a Unit column between Qty and Rate.
      _itemsTable(items, money,
          hidePrices: hidePrices, settings: s, isEstimate: isEstimate),
      pw.SizedBox(height: 10),
      if (!hidePrices) _totalsAndPayment(transaction, money, s, isEstimate: isEstimate),
      if (!hidePrices && s.amountInWordsFormat.isNotEmpty)
        _amountInWords(transaction.totalAmount, isEstimate: isEstimate),
      // HSN/SAC tax breakup table (sale invoices Format 1, and estimates).
      if ((isSale || isEstimate) && s.showTaxDetails) ...[
        pw.SizedBox(height: 10),
        _hsnTaxTable(items, transaction, money),
      ],
      pw.SizedBox(height: 16),
      // Delivery challans (hidePrices) suppress the bank/QR payment block.
      // Estimates keep it (Format 2 shows QR + bank on the left), so only
      // hidePrices drives suppression here.
      _footer(biz, transaction, hidePrices, money, s, isEstimate: isEstimate),
    ];
  }

  // ──────────────────────────────────────────────────────────────────────────
  // INVOICE FORMAT 1 — exact bordered layout (sale invoices only)
  // ──────────────────────────────────────────────────────────────────────────

  /// The Format 1 sale-invoice page: a boxed, bordered layout matching the
  /// reference screenshot — title row, 2-column header grid, Bill To, item
  /// table, amounts + in-words, HSN/SAC tax breakup, a 3-column footer (bank /
  /// QR-or-Terms / signature), and a "Powered by BusinessPro" line.
  ///
  /// Estimates/challans/purchases never reach here — they use the original
  /// borderless body in [_pageContent].
  static List<pw.Widget> _format1Page({
    required Map<dynamic, dynamic> biz,
    required dynamic party,
    required Transaction t,
    required List<TransactionItem> items,
    required String Function(num) money,
    required pw.MemoryImage? logo,
    required pw.MemoryImage? signature,
    required PrintSettings s,
    required String copyLabel,
  }) {
    const border = pw.BorderSide(color: PdfColors.grey600, width: 0.5);

    pw.Widget label(String txt) => pw.Text(txt,
        style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700));
    pw.Widget value(String txt) => pw.Text(txt,
        style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold));

    return [
      // ── Title row ──────────────────────────────────────────────────────
      // Copy label right-aligned on its own line, then the title centered.
      pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(copyLabel,
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
      ),
      pw.Center(
        child: pw.Text('Tax Invoice',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      ),
      pw.SizedBox(height: 6),

      // ── Header: business (left) + invoice meta grid (right) ────────────
      // Equal-width columns so both boxes align symmetrically.
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
        columnWidths: const {
          0: pw.FlexColumnWidth(1),
          1: pw.FlexColumnWidth(1),
        },
        children: [
          pw.TableRow(children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(8),
              child: _format1Business(biz, logo, s),
            ),
            _format1MetaGrid(t, label, value),
          ]),
        ],
      ),

      // ── Bill To (+ Ship To beside it when shipping differs) ─────────────
      if (t.isShippingDiff)
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
          columnWidths: const {
            0: pw.FlexColumnWidth(1),
            1: pw.FlexColumnWidth(1),
          },
          children: [
            pw.TableRow(children: [
              pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: _format1BillTo(party, t, s)),
              pw.Padding(
                  padding: const pw.EdgeInsets.all(6),
                  child: _format1ShipTo(t)),
            ]),
          ],
        )
      else
        pw.Container(
          width: double.infinity,
          decoration: pw.BoxDecoration(
            border: pw.Border(left: border, right: border, bottom: border),
          ),
          padding: const pw.EdgeInsets.all(6),
          child: _format1BillTo(party, t, s),
        ),

      // ── Item table ─────────────────────────────────────────────────────
      _format1ItemTable(items, money, s),

      // ── Amount in words (left) + amounts (right) ───────────────────────
      // Rendered as a 2-cell Table so it sizes to content (a stretch Row would
      // resolve to infinite height inside the MultiPage).
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
        columnWidths: const {
          0: pw.FlexColumnWidth(1),
          1: pw.FlexColumnWidth(1),
        },
        children: [
          pw.TableRow(children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(6),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  label('Invoice Amount In Words'),
                  pw.SizedBox(height: 3),
                  pw.Text(AmountToWords.rupees(t.totalAmount),
                      style: pw.TextStyle(
                          fontSize: 9, fontWeight: pw.FontWeight.bold)),
                ],
              ),
            ),
            pw.Column(children: [
              _format1AmountRow('Sub Total', money(t.subtotal)),
              _format1AmountRow('Total', money(t.totalAmount), bold: true),
              _format1AmountRow('Received', money(t.paidAmount)),
              _format1AmountRow('Balance', money(t.balanceAmount)),
            ]),
          ]),
        ],
      ),

      // ── HSN/SAC tax breakup (reused) ───────────────────────────────────
      // No gap above/below: the tax table sits flush so the whole invoice
      // reads as one continuous bordered bill.
      if (s.showTaxDetails && t.taxAmount > 0)
        _hsnTaxTable(items, t, money),

      // ── Footer: bank / QR-or-Terms / signature ─────────────────────────
      _format1Footer(biz, t, signature, s),

      // ── Powered by ─────────────────────────────────────────────────────
      pw.SizedBox(height: 4),
      pw.Center(
        child: pw.Text('Powered by BusinessPro',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey500)),
      ),
    ];
  }

  static pw.Widget _format1Business(
      Map<dynamic, dynamic> biz, pw.MemoryImage? logo, PrintSettings s) {
    final name = ((biz['name'] as String?) ?? 'My Business').trim();
    String line(String k) => ((biz[k] as String?) ?? '').trim();
    final cityState = [line('city'), line('state'), line('pincode')]
        .where((e) => e.isNotEmpty)
        .join(', ');
    // Business details column (name/address/contact/GSTIN), sat to the RIGHT
    // of the logo by the enclosing Row below.
    final details = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text(name,
            style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
        if (s.printAddress && line('address_line1').isNotEmpty)
          pw.Text(line('address_line1'), style: const pw.TextStyle(fontSize: 8)),
        if (s.printAddress && line('address_line2').isNotEmpty)
          pw.Text(line('address_line2'), style: const pw.TextStyle(fontSize: 8)),
        if (s.printAddress && cityState.isNotEmpty)
          pw.Text(cityState, style: const pw.TextStyle(fontSize: 8)),
        if (s.printPhone && line('phone').isNotEmpty)
          pw.Text('Phone no.: ${line('phone')}',
              style: const pw.TextStyle(fontSize: 8)),
        if (s.printEmail && line('email').isNotEmpty)
          pw.Text('Email: ${line('email')}',
              style: const pw.TextStyle(fontSize: 8)),
        if (s.printGstin && line('gstin').isNotEmpty)
          pw.Text('GSTIN: ${line('gstin')}',
              style: const pw.TextStyle(fontSize: 8)),
        if (line('state').isNotEmpty)
          pw.Text('State: ${line('state')}',
              style: const pw.TextStyle(fontSize: 8)),
      ],
    );
    // Logo on the left, details to its right. When no logo is shown the details
    // expand to fill the cell as before.
    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        if (s.printLogo && logo != null) ...[
          pw.Padding(
            // Nudge the logo down so it sits centered against the business
            // text rather than pinned to the top corner.
            padding: const pw.EdgeInsets.only(top: 15),
            child: pw.Container(
                height: 44,
                width: 60,
                child: pw.Image(logo,
                    fit: pw.BoxFit.contain, alignment: pw.Alignment.center)),
          ),
          pw.SizedBox(width: 8),
        ],
        pw.Expanded(child: details),
      ],
    );
  }

  static pw.Widget _format1MetaGrid(Transaction t,
      pw.Widget Function(String) label, pw.Widget Function(String) value) {
    // Eight cells in a 2-column grid: Invoice No / Date / Place of Supply /
    // Transport / Vehicle / Delivery Date / Delivery Location / E-Way Bill.
    final cells = <(String, String)>[
      ('Invoice No.', t.transactionNumber),
      ('Date', _dateFmt.format(_parseDate(t.transactionDate))),
      ('Place of Supply', (t.placeOfSupply ?? '').trim()),
      ('Transport Name', (t.transportName ?? '').trim()),
      ('Vehicle Number', (t.vehicleNumber ?? '').trim()),
      (
        'Delivery Date',
        (t.deliveryDate ?? '').trim().isEmpty
            ? ''
            : _dateFmt.format(_parseDate(t.deliveryDate!))
      ),
      ('Delivery Location', (t.deliveryLocation ?? '').trim()),
      ('E-Way Bill No.', (t.ewayBillNumber ?? '').trim()),
    ];
    // Render as a nested 2-column Table so it sizes to content inside the outer
    // header table cell (pw.Expanded would resolve to infinite height here).
    // All eight boxes always render (even when empty) so the grid stays a full
    // 4×2 — Place of Supply / Transport / Vehicle / etc. keep their slots.
    pw.Widget cell((String, String) c) => pw.Padding(
          padding: const pw.EdgeInsets.all(4),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [label(c.$1), value(c.$2)],
          ),
        );
    final tableRows = <pw.TableRow>[];
    for (var i = 0; i < cells.length; i += 2) {
      tableRows.add(pw.TableRow(children: [cell(cells[i]), cell(cells[i + 1])]));
    }
    // Internal dividers only (no outer box): the outer header table already
    // frames this cell. Drawing a full border here added a stray bottom line
    // below the last row when the cell stretched taller than the grid content.
    return pw.Table(
      border: const pw.TableBorder(
        horizontalInside:
            pw.BorderSide(color: PdfColors.grey600, width: 0.5),
        verticalInside: pw.BorderSide(color: PdfColors.grey600, width: 0.5),
      ),
      columnWidths: const {
        0: pw.FlexColumnWidth(1),
        1: pw.FlexColumnWidth(1),
      },
      children: tableRows,
    );
  }

  static pw.Widget _format1BillTo(dynamic party, Transaction t, PrintSettings s) {
    final name = (party?.name as String?) ?? t.displayPartyName ?? '';
    // Fall back to the document's one-off billing address/GSTIN when no party
    // is linked (typed directly on the invoice).
    final addr = ((party?.billingAddress as String?)?.trim().isNotEmpty ?? false)
        ? (party!.billingAddress as String).trim()
        : (t.billingAddress?.trim() ?? '');
    final cityState = [
      (party?.billingCity as String?)?.trim(),
      (party?.billingState as String?)?.trim(),
      (party?.billingPincode as String?)?.trim(),
    ].where((e) => e != null && e.isNotEmpty).join(', ');
    final phone = (party?.phone as String?)?.trim() ?? '';
    final partyGstin = (party?.gstin as String?)?.trim();
    final gstin = s.printGstin
        ? ((partyGstin != null && partyGstin.isNotEmpty)
            ? partyGstin
            : (t.billingGstin?.trim() ?? ''))
        : '';
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Bill To',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        pw.Text(name.isEmpty ? '—' : name,
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        if (addr.isNotEmpty)
          pw.Text(addr, style: const pw.TextStyle(fontSize: 8)),
        if (cityState.isNotEmpty)
          pw.Text(cityState, style: const pw.TextStyle(fontSize: 8)),
        if (phone.isNotEmpty)
          pw.Text('Contact No.: $phone',
              style: const pw.TextStyle(fontSize: 8)),
        if (gstin.isNotEmpty)
          pw.Text('GSTIN: $gstin', style: const pw.TextStyle(fontSize: 8)),
      ],
    );
  }

  /// "Ship To" cell rendered to the RIGHT of Bill To (Format 1) when the
  /// invoice carries a shipping address different from billing.
  static pw.Widget _format1ShipTo(Transaction t) {
    final addr = (t.shippingAddress ?? '').trim();
    final cityState = [
      (t.shippingCity ?? '').trim(),
      (t.shippingState ?? '').trim(),
      (t.shippingPincode ?? '').trim(),
    ].where((e) => e.isNotEmpty).join(', ');
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Ship To',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        if (addr.isNotEmpty)
          pw.Text(addr, style: const pw.TextStyle(fontSize: 8))
        else
          pw.Text('—', style: const pw.TextStyle(fontSize: 8)),
        if (cityState.isNotEmpty)
          pw.Text(cityState, style: const pw.TextStyle(fontSize: 8)),
      ],
    );
  }

  static pw.Widget _format1ItemTable(
      List<TransactionItem> items, String Function(num) money, PrintSettings s) {
    final headStyle = pw.TextStyle(
        fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
    const cellStyle = pw.TextStyle(fontSize: 8);
    final anyTax = items.any((it) => it.taxAmount > 0);

    pw.Widget c(String txt,
            {pw.TextStyle style = cellStyle,
            pw.Alignment align = pw.Alignment.centerLeft}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(txt, style: style),
        );

    final headers = <pw.Widget>[
      if (s.showSNo) c('#', style: headStyle),
      c('Item Name', style: headStyle),
      if (s.showHsn) c('HSN/SAC', style: headStyle),
      c('Qty', style: headStyle, align: pw.Alignment.centerRight),
      c('Unit', style: headStyle),
      c('Price/Unit', style: headStyle, align: pw.Alignment.centerRight),
      if (anyTax) c('GST', style: headStyle, align: pw.Alignment.centerRight),
      c('Amount', style: headStyle, align: pw.Alignment.centerRight),
    ];

    // Column widths split the table into two equal halves so the Qty|Unit
    // boundary sits exactly on the 50% midline — aligning with the vertical
    // lines that split Bill To|Ship To above and amount-in-words|breakup below.
    // Left group (#, Item, HSN, Qty) = 0.6+5.2+1.6+1.6 = 9.0; right group
    // (Unit, Price, GST, Amount) = 1.6+2.6+2.6+2.2 = 9.0. Item Name carries the
    // slack. Conditional columns (#/HSN/GST) just drop out without unbalancing.
    final colWidths = <int, pw.TableColumnWidth>{};
    var ci = 0;
    if (s.showSNo) colWidths[ci++] = const pw.FlexColumnWidth(0.6);
    colWidths[ci++] = const pw.FlexColumnWidth(5.2);
    if (s.showHsn) colWidths[ci++] = const pw.FlexColumnWidth(1.6);
    colWidths[ci++] = const pw.FlexColumnWidth(1.6);
    colWidths[ci++] = const pw.FlexColumnWidth(1.6);
    colWidths[ci++] = const pw.FlexColumnWidth(2.6);
    if (anyTax) colWidths[ci++] = const pw.FlexColumnWidth(2.6);
    colWidths[ci] = const pw.FlexColumnWidth(2.2);

    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.blue800),
        children: headers,
      ),
    ];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      rows.add(pw.TableRow(children: [
        if (s.showSNo) c('${i + 1}'),
        c(it.itemName),
        if (s.showHsn) c(it.itemHsn ?? ''),
        c(_qty(it.quantity, null), align: pw.Alignment.centerRight),
        c(it.unitName ?? ''),
        c(money(it.unitPrice), align: pw.Alignment.centerRight),
        if (anyTax)
          c(it.taxAmount > 0
              ? '${money(it.taxAmount)} (${_pct(it.taxRate)}%)'
              : '-',
              align: pw.Alignment.centerRight),
        c(money(it.totalAmount), align: pw.Alignment.centerRight),
      ]));
    }
    // Fill the remaining vertical space with a SINGLE tall empty row (not many
    // short ones) so there are no horizontal dividers in the blank area — just
    // the column verticals continue down, matching a professional invoice. The
    // height shrinks as item count grows, and collapses to zero once the items
    // already fill ~10 lines.
    const minRows = 10;
    final padLines = minRows - items.length;
    if (padLines > 0) {
      final fillHeight = padLines * 16.0;
      pw.Widget blank() => pw.Container(height: fillHeight);
      rows.add(pw.TableRow(children: [
        if (s.showSNo) blank(),
        blank(),
        if (s.showHsn) blank(),
        blank(),
        blank(),
        blank(),
        if (anyTax) blank(),
        blank(),
      ]));
    }
    // Total row.
    final totalQty = items.fold<double>(0, (s, it) => s + it.quantity);
    final grand = items.fold<double>(0, (s, it) => s + it.totalAmount);
    rows.add(pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.grey100),
      children: [
        if (s.showSNo) c(''),
        c('Total',
            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        if (s.showHsn) c(''),
        c(_qty(totalQty, null),
            align: pw.Alignment.centerRight,
            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        c(''), // Unit
        c(''), // Price/Unit
        if (anyTax) c(''),
        c(money(grand),
            align: pw.Alignment.centerRight,
            style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
      ],
    ));

    return pw.Table(
      columnWidths: colWidths,
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      children: rows,
    );
  }

  static pw.Widget _format1AmountRow(String labelTxt, String valueTxt,
      {bool bold = false}) {
    final style = pw.TextStyle(
        fontSize: 9,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal);
    return pw.Container(
      decoration: const pw.BoxDecoration(
          border: pw.Border(
              bottom: pw.BorderSide(color: PdfColors.grey300, width: 0.3))),
      padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [pw.Text(labelTxt, style: style), pw.Text(valueTxt, style: style)],
      ),
    );
  }

  static pw.Widget _format1Footer(
    Map<dynamic, dynamic> biz,
    Transaction t,
    pw.MemoryImage? signature,
    PrintSettings s,
  ) {
    final bizName = ((biz['name'] as String?) ?? 'My Business').trim();
    final upiId = ((biz['upi_id'] as String?) ?? '').trim();
    final printQr = ((biz['print_upi_qr_on_invoice'] as int?) ?? 1) == 1;
    final bankName = ((biz['bank_name'] as String?) ?? '').trim();
    final bankAcc = ((biz['bank_account_no'] as String?) ?? '').trim();
    final bankIfsc = ((biz['bank_ifsc'] as String?) ?? '').trim();

    // Center cell: UPI QR when an id is saved, else Terms & Conditions (Fix 2).
    final showQr = printQr && upiId.isNotEmpty;
    final terms = (t.termsConditions ?? '').trim().isNotEmpty
        ? (t.termsConditions ?? '').trim()
        : (s.termsConditionsText.trim().isNotEmpty
            ? s.termsConditionsText.trim()
            : 'Thank you for doing business with us.');

    pw.Widget bankCol() => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Bank Details',
                style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            if (bankName.isNotEmpty)
              pw.Text('Name: $bankName', style: const pw.TextStyle(fontSize: 8)),
            if (bankAcc.isNotEmpty)
              pw.Text('Account No.: $bankAcc',
                  style: const pw.TextStyle(fontSize: 8)),
            if (bankIfsc.isNotEmpty)
              pw.Text('IFSC code: $bankIfsc',
                  style: const pw.TextStyle(fontSize: 8)),
            if (bankName.isNotEmpty)
              pw.Text("Account Holder's Name: $bizName",
                  style: const pw.TextStyle(fontSize: 8)),
          ],
        );

    pw.Widget centerCol() => showQr
        ? pw.Column(
            mainAxisAlignment: pw.MainAxisAlignment.center,
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.BarcodeWidget(
                barcode: pw.Barcode.qrCode(),
                data: _upiUri(
                  upiId: upiId,
                  payeeName: bizName,
                  amount: t.balanceAmount > 0 ? t.balanceAmount : t.totalAmount,
                  note: t.transactionNumber,
                ),
                width: 70,
                height: 70,
                drawText: false,
              ),
              pw.SizedBox(height: 3),
              pw.Text('Scan to Pay', style: const pw.TextStyle(fontSize: 8)),
            ],
          )
        : pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text('Terms and conditions',
                  style:
                      pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
              pw.SizedBox(height: 3),
              pw.Text(terms, style: const pw.TextStyle(fontSize: 8)),
            ],
          );

    pw.Widget signCol() => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text('For: $bizName', style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 8),
            if (signature != null)
              pw.Container(height: 36, child: pw.Image(signature))
            else
              pw.SizedBox(height: 28),
            pw.SizedBox(height: 3),
            pw.Text(
                s.signatureText.isNotEmpty
                    ? s.signatureText
                    : 'Authorized Signatory',
                style: const pw.TextStyle(fontSize: 8)),
          ],
        );

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      columnWidths: const {
        0: pw.FlexColumnWidth(3),
        1: pw.FlexColumnWidth(3),
        2: pw.FlexColumnWidth(3),
      },
      children: [
        pw.TableRow(children: [
          pw.Padding(padding: const pw.EdgeInsets.all(6), child: bankCol()),
          pw.Padding(padding: const pw.EdgeInsets.all(6), child: centerCol()),
          pw.Padding(padding: const pw.EdgeInsets.all(6), child: signCol()),
        ]),
      ],
    );
  }

  // ──────────────────────────────────────────────────────────────────────────
  // ESTIMATE FORMAT 2 — exact bordered layout (estimates only)
  // ──────────────────────────────────────────────────────────────────────────

  /// The Format 2 estimate page: a boxed layout matching the reference
  /// screenshot — centered "Estimate" title (no copy label), header grid
  /// (business left; Estimate No + Date row then Place of Supply full-width
  /// right), "Estimate For" party block, item table with a **Unit** column and a
  /// GST cell showing amount over `(rate%)`, amount-in-words + Sub Total/Total
  /// only, HSN/SAC tax table with an IGST sub-header, and a 3-column footer
  /// (QR + bank LEFT, Terms CENTER, signature RIGHT) + "Powered by BusinessPro".
  static List<pw.Widget> _format2Page({
    required Map<dynamic, dynamic> biz,
    required dynamic party,
    required Transaction t,
    required List<TransactionItem> items,
    required String Function(num) money,
    required pw.MemoryImage? logo,
    required pw.MemoryImage? signature,
    required PrintSettings s,
  }) {
    const border = pw.BorderSide(color: PdfColors.grey600, width: 0.5);

    pw.Widget label(String txt) => pw.Text(txt,
        style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700));
    pw.Widget value(String txt) => pw.Text(txt,
        style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold));

    pw.Widget gridCell(String l, String v, {bool rightBorder = false}) =>
        pw.Container(
          padding: const pw.EdgeInsets.all(4),
          decoration: pw.BoxDecoration(
            border:
                pw.Border(right: rightBorder ? border : pw.BorderSide.none),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [label(l), value(v)],
          ),
        );

    return [
      // ── Title (centered, no copy label) ────────────────────────────────
      pw.Center(
        child: pw.Text('Estimate',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
      ),
      pw.SizedBox(height: 6),

      // ── Header: business (left) + Estimate No/Date/Place of Supply (right)
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
        columnWidths: const {
          0: pw.FlexColumnWidth(4),
          1: pw.FlexColumnWidth(5),
        },
        children: [
          pw.TableRow(children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(8),
              child: _format1Business(biz, logo, s),
            ),
            // Right: row of Estimate No | Date, then Place of Supply full width.
            pw.Column(
              children: [
                pw.Container(
                  decoration:
                      const pw.BoxDecoration(border: pw.Border(bottom: border)),
                  child: pw.Row(children: [
                    pw.Expanded(
                        child: gridCell('Estimate No.', t.transactionNumber,
                            rightBorder: true)),
                    pw.Expanded(
                        child: gridCell('Date',
                            _dateFmt.format(_parseDate(t.transactionDate)))),
                  ]),
                ),
                pw.Align(
                  alignment: pw.Alignment.centerLeft,
                  child: gridCell(
                      'Place of Supply', (t.placeOfSupply ?? '').trim()),
                ),
              ],
            ),
          ]),
        ],
      ),

      // ── Estimate For (party) ───────────────────────────────────────────
      pw.Container(
        width: double.infinity,
        decoration: pw.BoxDecoration(
          border: pw.Border(left: border, right: border, bottom: border),
        ),
        padding: const pw.EdgeInsets.all(6),
        child: _format2EstimateFor(party, s),
      ),

      // ── Item table (with Unit column + GST amount/%) ───────────────────
      _format2ItemTable(items, money, s),

      // ── Amount in words (left) + amounts: Sub Total + Total only (right) ─
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
        columnWidths: const {
          0: pw.FlexColumnWidth(5),
          1: pw.FlexColumnWidth(4),
        },
        children: [
          pw.TableRow(children: [
            pw.Padding(
              padding: const pw.EdgeInsets.all(6),
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  label('Estimate Amount In Words'),
                  pw.SizedBox(height: 3),
                  pw.Text(AmountToWords.rupees(t.totalAmount),
                      style: pw.TextStyle(
                          fontSize: 9, fontWeight: pw.FontWeight.bold)),
                ],
              ),
            ),
            pw.Column(children: [
              _format1AmountRow('Sub Total', money(t.subtotal)),
              _format1AmountRow('Total', money(t.totalAmount), bold: true),
            ]),
          ]),
        ],
      ),

      // ── HSN/SAC tax breakup (reused) ───────────────────────────────────
      if (s.showTaxDetails && t.taxAmount > 0) ...[
        pw.SizedBox(height: 8),
        _hsnTaxTable(items, t, money),
      ],

      // ── Footer: QR+bank LEFT / Terms CENTER / signature RIGHT ───────────
      pw.SizedBox(height: 8),
      _format2Footer(biz, t, signature, s),

      // ── Powered by ─────────────────────────────────────────────────────
      pw.SizedBox(height: 4),
      pw.Center(
        child: pw.Text('Powered by BusinessPro',
            style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey500)),
      ),
    ];
  }

  /// "Estimate For" party block: label (grey), name (bold), city/state,
  /// "GSTIN Number:" and "State:" lines.
  static pw.Widget _format2EstimateFor(dynamic party, PrintSettings s) {
    final name = (party?.name as String?) ?? '';
    final addr = (party?.billingAddress as String?)?.trim() ?? '';
    final cityState = [
      (party?.billingCity as String?)?.trim(),
      (party?.billingState as String?)?.trim(),
    ].where((e) => e != null && e.isNotEmpty).join(', ');
    final gstin = s.printGstin ? ((party?.gstin as String?)?.trim() ?? '') : '';
    final state = (party?.billingState as String?)?.trim() ?? '';
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Text('Estimate For',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        pw.Text(name.isEmpty ? '—' : name,
            style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        if (addr.isNotEmpty)
          pw.Text(addr, style: const pw.TextStyle(fontSize: 8)),
        if (cityState.isNotEmpty)
          pw.Text(cityState, style: const pw.TextStyle(fontSize: 8)),
        if (gstin.isNotEmpty)
          pw.Text('GSTIN Number: $gstin',
              style: const pw.TextStyle(fontSize: 8)),
        if (state.isNotEmpty)
          pw.Text('State: $state', style: const pw.TextStyle(fontSize: 8)),
      ],
    );
  }

  /// Estimate item table: `# | Item | HSN/SAC | Qty | Unit | Price/Unit | GST |
  /// Amount`. The GST cell stacks the tax amount over `(rate%)`.
  static pw.Widget _format2ItemTable(
      List<TransactionItem> items, String Function(num) money, PrintSettings s) {
    final headStyle = pw.TextStyle(
        fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
    const cellStyle = pw.TextStyle(fontSize: 8);
    final anyTax = items.any((it) => it.taxAmount > 0);

    pw.Widget c(String txt,
            {pw.TextStyle style = cellStyle,
            pw.Alignment align = pw.Alignment.centerLeft}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(txt, style: style),
        );

    // GST cell: amount on top, (rate%) below in smaller grey text.
    pw.Widget gstCell(TransactionItem it) => pw.Container(
          alignment: pw.Alignment.centerRight,
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: it.taxAmount > 0
              ? pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(money(it.taxAmount),
                        style: const pw.TextStyle(fontSize: 8)),
                    pw.Text('(${_pct(it.taxRate)}%)',
                        style: const pw.TextStyle(
                            fontSize: 7, color: PdfColors.grey700)),
                  ],
                )
              : pw.Text('-', style: cellStyle),
        );

    final headers = <pw.Widget>[
      if (s.showSNo) c('#', style: headStyle),
      c('Item Name', style: headStyle),
      if (s.showHsn) c('HSN/SAC', style: headStyle),
      c('Qty', style: headStyle, align: pw.Alignment.centerRight),
      c('Unit', style: headStyle),
      c('Price/Unit', style: headStyle, align: pw.Alignment.centerRight),
      if (anyTax) c('GST', style: headStyle, align: pw.Alignment.centerRight),
      c('Amount', style: headStyle, align: pw.Alignment.centerRight),
    ];

    final colWidths = <int, pw.TableColumnWidth>{};
    var ci = 0;
    if (s.showSNo) colWidths[ci++] = const pw.FixedColumnWidth(20);
    colWidths[ci++] = const pw.FlexColumnWidth(4);
    if (s.showHsn) colWidths[ci++] = const pw.FlexColumnWidth(1.6);
    colWidths[ci++] = const pw.FlexColumnWidth(1.1);
    colWidths[ci++] = const pw.FlexColumnWidth(1.0);
    colWidths[ci++] = const pw.FlexColumnWidth(1.8);
    if (anyTax) colWidths[ci++] = const pw.FlexColumnWidth(1.4);
    colWidths[ci] = const pw.FlexColumnWidth(1.8);

    final rows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.blue800),
        children: headers,
      ),
    ];
    for (var i = 0; i < items.length; i++) {
      final it = items[i];
      rows.add(pw.TableRow(children: [
        if (s.showSNo) c('${i + 1}'),
        c(it.itemName),
        if (s.showHsn) c(it.itemHsn ?? ''),
        c(_qty(it.quantity, null), align: pw.Alignment.centerRight),
        c(it.unitName ?? ''),
        c(money(it.unitPrice), align: pw.Alignment.centerRight),
        if (anyTax) gstCell(it),
        c(money(it.totalAmount), align: pw.Alignment.centerRight),
      ]));
    }
    final totalQty = items.fold<double>(0, (s, it) => s + it.quantity);
    final grandTax = items.fold<double>(0, (s, it) => s + it.taxAmount);
    final grand = items.fold<double>(0, (s, it) => s + it.totalAmount);
    final boldS = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);
    rows.add(pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.grey100),
      children: [
        if (s.showSNo) c(''),
        c('Total', style: boldS),
        if (s.showHsn) c(''),
        c(_qty(totalQty, null), align: pw.Alignment.centerRight, style: boldS),
        c(''),
        c(''),
        if (anyTax) c(money(grandTax), align: pw.Alignment.centerRight, style: boldS),
        c(money(grand), align: pw.Alignment.centerRight, style: boldS),
      ],
    ));

    return pw.Table(
      columnWidths: colWidths,
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      children: rows,
    );
  }

  /// Estimate footer: QR + bank LEFT, Terms CENTER, signature RIGHT.
  static pw.Widget _format2Footer(
    Map<dynamic, dynamic> biz,
    Transaction t,
    pw.MemoryImage? signature,
    PrintSettings s,
  ) {
    final bizName = ((biz['name'] as String?) ?? 'My Business').trim();
    final upiId = ((biz['upi_id'] as String?) ?? '').trim();
    final printQr = ((biz['print_upi_qr_on_invoice'] as int?) ?? 1) == 1;
    final bankName = ((biz['bank_name'] as String?) ?? '').trim();
    final bankAcc = ((biz['bank_account_no'] as String?) ?? '').trim();
    final bankIfsc = ((biz['bank_ifsc'] as String?) ?? '').trim();
    final showQr = printQr && upiId.isNotEmpty;
    final terms = (t.termsConditions ?? '').trim().isNotEmpty
        ? (t.termsConditions ?? '').trim()
        : (s.termsConditionsText.trim().isNotEmpty
            ? s.termsConditionsText.trim()
            : 'Thank you for doing business with us.');

    pw.Widget leftCol() => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Bank Details',
                style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            if (showQr) ...[
              pw.SizedBox(height: 4),
              pw.BarcodeWidget(
                barcode: pw.Barcode.qrCode(),
                data: _upiUri(
                  upiId: upiId,
                  payeeName: bizName,
                  amount: t.totalAmount,
                  note: t.transactionNumber,
                ),
                width: 60,
                height: 60,
                drawText: false,
              ),
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 2),
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                color: PdfColors.green,
                child: pw.Text('UPI SCAN TO PAY',
                    style: pw.TextStyle(
                        fontSize: 6,
                        color: PdfColors.white,
                        fontWeight: pw.FontWeight.bold)),
              ),
              pw.SizedBox(height: 4),
            ],
            if (bankName.isNotEmpty)
              pw.Text('Name: $bankName', style: const pw.TextStyle(fontSize: 8)),
            if (bankAcc.isNotEmpty)
              pw.Text('Account No.: $bankAcc',
                  style: const pw.TextStyle(fontSize: 8)),
            if (bankIfsc.isNotEmpty)
              pw.Text('IFSC code: $bankIfsc',
                  style: const pw.TextStyle(fontSize: 8)),
            if (bankName.isNotEmpty)
              pw.Text("Account Holder's Name: $bizName",
                  style: const pw.TextStyle(fontSize: 8)),
          ],
        );

    pw.Widget centerCol() => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('Terms and conditions',
                style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 3),
            pw.Text(terms, style: const pw.TextStyle(fontSize: 8)),
          ],
        );

    pw.Widget signCol() => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text('For: $bizName', style: const pw.TextStyle(fontSize: 9)),
            pw.SizedBox(height: 8),
            if (signature != null)
              pw.Container(height: 35, child: pw.Image(signature))
            else
              pw.SizedBox(height: 28),
            pw.SizedBox(height: 3),
            pw.Text(
                s.signatureText.isNotEmpty
                    ? s.signatureText
                    : 'Authorized Signatory',
                style: const pw.TextStyle(fontSize: 8)),
          ],
        );

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.5),
      columnWidths: const {
        0: pw.FlexColumnWidth(3),
        1: pw.FlexColumnWidth(3),
        2: pw.FlexColumnWidth(3),
      },
      children: [
        pw.TableRow(children: [
          pw.Padding(padding: const pw.EdgeInsets.all(6), child: leftCol()),
          pw.Padding(padding: const pw.EdgeInsets.all(6), child: centerCol()),
          pw.Padding(padding: const pw.EdgeInsets.all(6), child: signCol()),
        ]),
      ],
    );
  }

  // ── Header: business identity + invoice meta ──────────────────────────────

  static pw.Widget _header(
    Map<dynamic, dynamic> biz,
    String docTitle,
    Transaction t,
    String Function(num) money,
    pw.MemoryImage? logo,
    PrintSettings s, {
    String? copyLabel,
    bool isEstimate = false,
  }) {
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

    // Header fields are gated by PrintSettings toggles.
    final gstin = s.printGstin ? ((biz['gstin'] as String?) ?? '').trim() : '';
    final phone = s.printPhone ? ((biz['phone'] as String?) ?? '').trim() : '';
    final email = s.printEmail ? ((biz['email'] as String?) ?? '').trim() : '';
    final showAddress = s.printAddress;
    final companyFontSize = s.companyNameTextSize == 'small'
        ? 14.0
        : s.companyNameTextSize == 'large'
            ? 18.0
            : 16.0;

    return pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (s.printLogo && logo != null) ...[
                pw.Container(
                  height: 48,
                  constraints: const pw.BoxConstraints(maxWidth: 140),
                  child: pw.Image(logo, fit: pw.BoxFit.contain,
                      alignment: pw.Alignment.centerLeft),
                ),
                pw.SizedBox(height: 6),
              ],
              if (s.printCompanyName)
                pw.Text(
                  bizName?.isNotEmpty == true ? bizName! : 'My Business',
                  style: pw.TextStyle(
                      fontSize: companyFontSize,
                      fontWeight: pw.FontWeight.bold),
                ),
              pw.SizedBox(height: 2),
              if (showAddress)
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
            // Copy label (Format 1) in the top-right corner.
            if (copyLabel != null && copyLabel.isNotEmpty) ...[
              pw.Text(copyLabel,
                  style: pw.TextStyle(
                      fontSize: 8,
                      fontWeight: pw.FontWeight.bold,
                      color: PdfColors.grey700)),
              pw.SizedBox(height: 2),
            ],
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
            // Estimate Format 2: Place of Supply in the header (no transport
            // grid for estimates).
            if (isEstimate && (t.placeOfSupply ?? '').trim().isNotEmpty)
              _metaRow('Place of Supply', t.placeOfSupply!.trim()),
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

  // ── Transport & delivery grid (Format 1) ──────────────────────────────────

  /// A compact 2-column grid of transport / delivery fields, shown under the
  /// header on sale invoices. Renders nothing when no field is set, so a plain
  /// invoice is unaffected.
  static pw.Widget _transportGrid(Transaction t) {
    final pairs = <(String, String)>[
      if ((t.placeOfSupply ?? '').trim().isNotEmpty)
        ('Place of Supply', t.placeOfSupply!.trim()),
      if ((t.transportName ?? '').trim().isNotEmpty)
        ('Transport', t.transportName!.trim()),
      if ((t.vehicleNumber ?? '').trim().isNotEmpty)
        ('Vehicle No.', t.vehicleNumber!.trim()),
      if ((t.deliveryDate ?? '').trim().isNotEmpty)
        ('Delivery Date', _dateFmt.format(_parseDate(t.deliveryDate!))),
      if ((t.deliveryLocation ?? '').trim().isNotEmpty)
        ('Delivery Location', t.deliveryLocation!.trim()),
      if ((t.ewayBillNumber ?? '').trim().isNotEmpty)
        ('E-Way Bill No.', t.ewayBillNumber!.trim()),
    ];
    if (pairs.isEmpty) return pw.SizedBox();

    pw.Widget cell((String, String) p) => pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          child: pw.RichText(
            text: pw.TextSpan(children: [
              pw.TextSpan(
                  text: '${p.$1}: ',
                  style: const pw.TextStyle(
                      fontSize: 8, color: PdfColors.grey700)),
              pw.TextSpan(
                  text: p.$2,
                  style: pw.TextStyle(
                      fontSize: 8, fontWeight: pw.FontWeight.bold)),
            ]),
          ),
        );

    // Lay out in rows of two columns.
    final rows = <pw.TableRow>[];
    for (var i = 0; i < pairs.length; i += 2) {
      rows.add(pw.TableRow(children: [
        cell(pairs[i]),
        i + 1 < pairs.length ? cell(pairs[i + 1]) : pw.SizedBox(),
      ]));
    }

    return pw.Container(
      margin: const pw.EdgeInsets.only(top: 8),
      child: pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
        columnWidths: const {
          0: pw.FlexColumnWidth(1),
          1: pw.FlexColumnWidth(1),
        },
        children: rows,
      ),
    );
  }

  // ── HSN/SAC tax breakup (Format 1) ─────────────────────────────────────────

  /// HSN/SAC-wise tax breakup table: taxable amount, rate, CGST/SGST or IGST,
  /// and total tax per HSN, with a totals row. Renders nothing when the invoice
  /// carries no tax.
  static pw.Widget _hsnTaxTable(
    List<TransactionItem> items,
    Transaction t,
    String Function(num) money,
  ) {
    if (t.taxAmount <= 0) return pw.SizedBox();
    final interState = t.igstAmount > 0;

    // Group lines by HSN (blank HSN collapses into one '—' bucket).
    final byHsn = <String, ({double taxable, double cgst, double sgst, double igst, double tax, double rate})>{};
    for (final it in items) {
      if (it.taxAmount <= 0) continue;
      final key = (it.itemHsn ?? '').trim().isEmpty ? '—' : it.itemHsn!.trim();
      final cur = byHsn[key] ??
          (taxable: 0.0, cgst: 0.0, sgst: 0.0, igst: 0.0, tax: 0.0, rate: it.taxRate);
      byHsn[key] = (
        taxable: cur.taxable + it.taxableAmount,
        cgst: cur.cgst + it.cgstAmount,
        sgst: cur.sgst + it.sgstAmount,
        igst: cur.igst + it.igstAmount,
        tax: cur.tax + it.taxAmount,
        rate: it.taxRate,
      );
    }
    if (byHsn.isEmpty) return pw.SizedBox();

    final headStyle = pw.TextStyle(
        fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
    final boldS = pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold);
    const cellStyle = pw.TextStyle(fontSize: 8);
    const headColor = PdfColors.blue800;
    const headBorder = pw.BorderSide(color: PdfColors.white, width: 0.5);

    pw.Widget c(String txt,
            {pw.TextStyle style = cellStyle,
            pw.Alignment align = pw.Alignment.centerRight}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(txt, style: style),
        );

    // A header cell that spans the full height of the two-row header band: the
    // label is vertically centered, no sub-columns (HSN/SAC, Taxable, Total).
    pw.Widget headSpan(String txt, {pw.Alignment align = pw.Alignment.center}) =>
        pw.Container(
          alignment: align,
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(txt, style: headStyle),
        );

    // A grouped header ("CGST"/"SGST"/"IGST") spanning two sub-columns
    // (Rate | Amount). Built as a nested 2-row table whose second row is itself
    // a 2-column table — no Row/Expanded, which would crash with unbounded
    // width inside a Table cell.
    pw.Widget headCenter(String txt) => pw.Container(
          alignment: pw.Alignment.center,
          padding: const pw.EdgeInsets.symmetric(vertical: 2),
          child: pw.Text(txt, style: headStyle),
        );
    pw.Widget headGroup(String title) => pw.Table(
          border: const pw.TableBorder(horizontalInside: headBorder),
          children: [
            pw.TableRow(children: [
              pw.Container(
                alignment: pw.Alignment.center,
                padding: const pw.EdgeInsets.symmetric(vertical: 3),
                child: pw.Text(title, style: headStyle),
              ),
            ]),
            pw.TableRow(children: [
              pw.Table(
                border: const pw.TableBorder(verticalInside: headBorder),
                columnWidths: const {
                  0: pw.FlexColumnWidth(1),
                  1: pw.FlexColumnWidth(1.6),
                },
                children: [
                  pw.TableRow(children: [
                    headCenter('Rate'),
                    headCenter('Amount'),
                  ]),
                ],
              ),
            ]),
          ],
        );

    // ── Leaf columns ───────────────────────────────────────────────────────
    // Intra-state: HSN | Taxable | CGST-Rate | CGST-Amt | SGST-Rate | SGST-Amt | Total
    // Inter-state: HSN | Taxable | IGST-Rate | IGST-Amt | Total
    final colWidths = <int, pw.TableColumnWidth>{
      0: const pw.FlexColumnWidth(2.2), // HSN/SAC
      1: const pw.FlexColumnWidth(2.6), // Taxable
    };
    if (interState) {
      colWidths[2] = const pw.FlexColumnWidth(1.2); // IGST Rate
      colWidths[3] = const pw.FlexColumnWidth(2.2); // IGST Amount
      colWidths[4] = const pw.FlexColumnWidth(2.4); // Total Tax
    } else {
      colWidths[2] = const pw.FlexColumnWidth(1.2); // CGST Rate
      colWidths[3] = const pw.FlexColumnWidth(2.0); // CGST Amount
      colWidths[4] = const pw.FlexColumnWidth(1.2); // SGST Rate
      colWidths[5] = const pw.FlexColumnWidth(2.0); // SGST Amount
      colWidths[6] = const pw.FlexColumnWidth(2.4); // Total Tax
    }

    // ── Two-row grouped header, rendered as one TableRow whose cells are the
    // spanning widgets above; each group widget internally splits into its two
    // leaf sub-columns. To keep leaf columns aligned with the data rows, the
    // header is a SEPARATE table laid over the same column widths.
    final headerTable = pw.Table(
      columnWidths: {
        0: colWidths[0]!,
        1: colWidths[1]!,
        2: interState
            ? const pw.FlexColumnWidth(3.4) // IGST group (rate+amt)
            : const pw.FlexColumnWidth(3.2), // CGST group
        if (!interState) 3: const pw.FlexColumnWidth(3.2), // SGST group
        (interState ? 3 : 4): const pw.FlexColumnWidth(2.4), // Total Tax
      },
      border: pw.TableBorder.all(color: PdfColors.white, width: 0.5),
      children: [
        pw.TableRow(
          decoration: const pw.BoxDecoration(color: headColor),
          children: [
            headSpan('HSN/SAC', align: pw.Alignment.centerLeft),
            headSpan('Taxable\nAmount'),
            if (interState)
              headGroup('IGST')
            else ...[
              headGroup('CGST'),
              headGroup('SGST'),
            ],
            headSpan('Total Tax\nAmount'),
          ],
        ),
      ],
    );

    // ── Data + total rows (leaf columns) ─────────────────────────────────────
    final dataRows = <pw.TableRow>[];
    byHsn.forEach((hsn, v) {
      // CGST/SGST rate is half the line's GST rate (e.g. 5% → 2.5% each).
      final halfRate = '${_pct(v.rate / 2)}%';
      dataRows.add(pw.TableRow(children: [
        c(hsn, align: pw.Alignment.centerLeft),
        c(money(v.taxable)),
        if (interState) ...[
          c('${_pct(v.rate)}%'),
          c(money(v.igst)),
        ] else ...[
          c(halfRate),
          c(money(v.cgst)),
          c(halfRate),
          c(money(v.sgst)),
        ],
        c(money(v.tax)),
      ]));
    });

    dataRows.add(pw.TableRow(
      decoration: const pw.BoxDecoration(color: PdfColors.grey100),
      children: [
        c('Total', style: boldS, align: pw.Alignment.centerLeft),
        c(money(t.taxableAmount), style: boldS),
        if (interState) ...[
          c(''),
          c(money(t.igstAmount), style: boldS),
        ] else ...[
          c(''),
          c(money(t.cgstAmount), style: boldS),
          c(''),
          c(money(t.sgstAmount), style: boldS),
        ],
        c(money(t.taxAmount), style: boldS),
      ],
    ));

    final bodyTable = pw.Table(
      columnWidths: colWidths,
      border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
      children: dataRows,
    );

    // No outer margin: callers control the spacing above the table (Format 1
    // wants it flush; the borderless/Format 2 layouts add their own SizedBox).
    return pw.Column(children: [headerTable, bodyTable]);
  }

  // ── Bill-to party ─────────────────────────────────────────────────────────

  static pw.Widget _partySection(
    Map<dynamic, dynamic> biz,
    dynamic party,
    Transaction t,
    PrintSettings s, {
    bool isEstimate = false,
  }) {
    final isPurchase = t.transactionType == TxnTypes.purchase;
    // Estimate Format 2 labels the recipient "Estimate For".
    final heading =
        isEstimate ? 'Estimate For' : (isPurchase ? 'Bill From' : 'Bill To');

    final name = party?.name as String? ?? t.displayPartyName ?? '';
    final partyAddr = (party?.billingAddress as String?)?.trim();
    final addr = <String>[
      if (partyAddr != null && partyAddr.isNotEmpty)
        partyAddr
      else if ((t.billingAddress?.trim() ?? '').isNotEmpty)
        t.billingAddress!.trim(),
      [
        (party?.billingCity as String?)?.trim(),
        (party?.billingState as String?)?.trim(),
        (party?.billingPincode as String?)?.trim(),
      ].where((s) => s != null && s.isNotEmpty).join(', '),
    ].where((s) => s.trim().isNotEmpty).toList();
    final partyGstinRaw = (party?.gstin as String?)?.trim();
    final partyGstin = s.printGstin
        ? ((partyGstinRaw != null && partyGstinRaw.isNotEmpty)
            ? partyGstinRaw
            : (t.billingGstin?.trim() ?? ''))
        : '';
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
          // Estimate Format 2 omits the phone line and labels GSTIN / State
          // explicitly; invoices keep the phone + short GSTIN label.
          if (!isEstimate && partyPhone.isNotEmpty)
            pw.Text('Ph: $partyPhone', style: const pw.TextStyle(fontSize: 9)),
          if (partyGstin.isNotEmpty)
            pw.Text(
                isEstimate
                    ? 'GSTIN Number: $partyGstin'
                    : 'GSTIN: $partyGstin',
                style: const pw.TextStyle(fontSize: 9)),
          if (isEstimate &&
              ((party?.billingState as String?)?.trim().isNotEmpty ?? false))
            pw.Text('State: ${(party!.billingState as String).trim()}',
                style: const pw.TextStyle(fontSize: 9)),
          // Ship-to block (Format 1) when a different shipping address was set.
          if (t.isShippingDiff) ..._shipTo(t),
        ],
      ),
    );
  }

  /// "Ship To" lines appended to the party section when the invoice carries a
  /// shipping address distinct from billing.
  static List<pw.Widget> _shipTo(Transaction t) {
    final lines = <String>[
      if ((t.shippingAddress ?? '').trim().isNotEmpty)
        t.shippingAddress!.trim(),
      [
        (t.shippingCity ?? '').trim(),
        (t.shippingState ?? '').trim(),
        (t.shippingPincode ?? '').trim(),
      ].where((s) => s.isNotEmpty).join(', '),
    ].where((s) => s.trim().isNotEmpty).toList();
    if (lines.isEmpty) return [];
    return [
      pw.SizedBox(height: 4),
      pw.Text('Ship To:',
          style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
      for (final line in lines)
        pw.Text(line, style: const pw.TextStyle(fontSize: 9)),
    ];
  }

  // ── Line items table ──────────────────────────────────────────────────────

  static pw.Widget _itemsTable(
    List<TransactionItem> items,
    String Function(num) money, {
    bool hidePrices = false,
    required PrintSettings settings,
    bool isEstimate = false,
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
    // Estimate Format 2 has a dedicated Unit column between Qty and Rate; the
    // Qty cell then shows the bare number (no unit suffix).
    final showUnitCol = isEstimate;

    final headers = <pw.Widget>[
      cell(settings.showSNo ? '#' : '', style: headerStyle),
      cell('Item', style: headerStyle),
      cell('Qty', style: headerStyle, align: pw.Alignment.centerRight),
      if (showUnitCol) cell('Unit', style: headerStyle),
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
    if (showUnitCol) columnWidths[next++] = const pw.FlexColumnWidth(1.2);
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
          cell(settings.showSNo ? '${i + 1}' : ''),
          cell(
            it.itemName +
                (settings.showHsn &&
                        it.itemHsn != null &&
                        it.itemHsn!.isNotEmpty
                    ? '\nHSN: ${it.itemHsn}'
                    : ''),
          ),
          // With a Unit column the Qty cell is the bare number; otherwise it
          // keeps the inline unit suffix (e.g. "1 Pcs").
          cell(showUnitCol ? _qty(it.quantity, null) : _qty(it.quantity, it.unitName),
              align: pw.Alignment.centerRight),
          if (showUnitCol) cell(it.unitName ?? ''),
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

  static pw.Widget _totalsAndPayment(
      Transaction t, String Function(num) money, PrintSettings s,
      {bool isEstimate = false}) {
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
              if (s.showTaxDetails) ...[
                if (t.cgstAmount > 0) line('CGST', t.cgstAmount),
                if (t.sgstAmount > 0) line('SGST', t.sgstAmount),
                if (t.igstAmount > 0) line('IGST', t.igstAmount),
              ],
              if (t.roundOff != 0) line('Round Off', t.roundOff),
              pw.Divider(height: 8, color: PdfColors.grey400),
              line('Total', t.totalAmount, bold: true),
              // An estimate is a quotation, not a payment document: no Paid /
              // Balance / You Saved rows (Format 2 = Sub Total + Total only).
              if (!isEstimate) ...[
                if (s.showReceivedAmount && t.paidAmount > 0)
                  line('Paid', t.paidAmount, color: PdfColors.green800),
                if (s.showBalanceAmount && t.balanceAmount > 0)
                  line('Balance Due', t.balanceAmount,
                      bold: true, color: PdfColors.red800),
                if (s.showYouSaved && t.discountAmount > 0)
                  line('You Saved', t.discountAmount, color: PdfColors.green800),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── Amount in words ───────────────────────────────────────────────────────

  static pw.Widget _amountInWords(double total, {bool isEstimate = false}) {
    return pw.Container(
      width: double.infinity,
      margin: const pw.EdgeInsets.only(top: 8),
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey100,
        borderRadius: pw.BorderRadius.circular(4),
      ),
      child: pw.RichText(
        text: pw.TextSpan(
          children: [
            pw.TextSpan(
              text: isEstimate
                  ? 'Estimate amount in words: '
                  : 'Amount in words: ',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
            ),
            pw.TextSpan(
              text: AmountToWords.rupees(total),
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  // ── Footer: bank details, UPI QR, notes, signature ────────────────────────

  static pw.Widget _footer(
    Map<dynamic, dynamic> biz,
    Transaction t,
    bool suppressPayment,
    String Function(num) money,
    PrintSettings s, {
    bool isEstimate = false,
  }) {
    final printBank = ((biz['print_bank_on_invoice'] as int?) ?? 1) == 1;
    final printQr = ((biz['print_upi_qr_on_invoice'] as int?) ?? 1) == 1;
    final upiId = ((biz['upi_id'] as String?) ?? '').trim();
    final bizName = ((biz['name'] as String?) ?? 'My Business').trim();

    final bankName = ((biz['bank_name'] as String?) ?? '').trim();
    final bankAcc = ((biz['bank_account_no'] as String?) ?? '').trim();
    final bankIfsc = ((biz['bank_ifsc'] as String?) ?? '').trim();
    final hasBank = bankName.isNotEmpty || bankAcc.isNotEmpty || bankIfsc.isNotEmpty;

    // [suppressPayment] hides the bank/QR block (delivery challans). For a sale
    // invoice [build] passes false → bank + QR show. Estimate Format 2 also
    // shows the QR + bank (on the left) alongside a Terms column, so it sets
    // suppressPayment=false too.
    final showBank = !suppressPayment && printBank && hasBank;
    final showQr = !suppressPayment && printQr && upiId.isNotEmpty;

    // Bank details column, reused by invoice and estimate footers.
    pw.Widget bankColumn() => pw.Column(
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
              pw.Text('UPI: $upiId', style: const pw.TextStyle(fontSize: 9)),
          ],
        );

    // UPI scan-to-pay QR, reused by invoice and estimate footers.
    pw.Widget qrColumn() => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text('Scan to Pay',
                style:
                    pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold)),
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
              drawText: false,
            ),
            pw.SizedBox(height: 2),
            pw.Text(
              money(t.balanceAmount > 0 ? t.balanceAmount : t.totalAmount),
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
          ],
        );

    final notes = s.printDescription ? (t.notes ?? '').trim() : '';
    // Prefer the transaction's own terms; fall back to the configured default
    // when terms-printing is on and the transaction has none.
    final txnTerms = (t.termsConditions ?? '').trim();
    final terms = s.printTermsConditions
        ? (txnTerms.isNotEmpty ? txnTerms : s.termsConditionsText.trim())
        : '';

    // Signature column (shared), gated by the print setting.
    final signature = !s.printSignatureText
        ? null
        : pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text('For $bizName', style: const pw.TextStyle(fontSize: 9)),
              pw.SizedBox(height: 28),
              pw.Text(
                  s.signatureText.isNotEmpty
                      ? s.signatureText
                      : 'Authorised Signatory',
                  style:
                      const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
            ],
          );

    // ── Estimate Format 2 footer: QR + bank LEFT, Terms CENTER, Sign RIGHT ──
    if (isEstimate) {
      return pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          // Left: QR (if any) above bank details.
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                if (showQr) ...[qrColumn(), pw.SizedBox(height: 6)],
                if (showBank) bankColumn(),
              ],
            ),
          ),
          // Center: Terms & Conditions.
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text('Terms and conditions',
                    style: pw.TextStyle(
                        fontSize: 9, fontWeight: pw.FontWeight.bold)),
                pw.SizedBox(height: 2),
                pw.Text(terms.isNotEmpty ? terms : 'Thank you for your business!',
                    style:
                        const pw.TextStyle(fontSize: 9, color: PdfColors.grey800)),
                if (notes.isNotEmpty) ...[
                  pw.SizedBox(height: 4),
                  pw.Text('Notes: $notes',
                      style: const pw.TextStyle(
                          fontSize: 9, color: PdfColors.grey800)),
                ],
              ],
            ),
          ),
          // Right: signature.
          if (signature != null)
            pw.Expanded(
                child: pw.Align(
                    alignment: pw.Alignment.bottomCenter, child: signature)),
        ],
      );
    }

    // ── Invoice Format 1 / default footer (bank left, QR center) ───────────
    final widgets = <pw.Widget>[];

    if (showBank || showQr) {
      widgets.add(
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (showBank) pw.Expanded(child: bankColumn()),
            if (showQr) qrColumn(),
          ],
        ),
      );
    }

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

    if (signature != null) {
      widgets.add(pw.SizedBox(height: 20));
      widgets.add(
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.end, children: [signature]),
      );
    }

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
