import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/database_helper.dart';
import '../models/inventory_item.dart';

/// Builds an A4 inventory stock-summary PDF: one row per item (stock, unit,
/// purchase price, stock value) plus a totals footer. Mirrors the other PDF
/// services' font handling (the default PDF font lacks the ₹ glyph, so the
/// bundled Noto Sans family is loaded and used for all text).
class InventoryPdfService {
  InventoryPdfService._();

  static final _amountFmt = NumberFormat('#,##,##0.00', 'en_IN');
  static final _qtyFmt = NumberFormat('#,##,##0.###', 'en_IN');
  static final _dateFmt = DateFormat('dd MMM yyyy, hh:mm a');

  static pw.Font? _regular;
  static pw.Font? _bold;

  static Future<void> _ensureFonts() async {
    if (_regular != null && _bold != null) return;
    final reg = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
    _regular = pw.Font.ttf(reg);
    _bold = pw.Font.ttf(bold);
  }

  static Future<Uint8List> build(List<InventoryItem> items) async {
    await _ensureFonts();
    final biz = await DatabaseHelper.getBusiness() ?? const {};
    final symbol = (biz['currency_symbol'] as String?) ?? '₹';
    String money(num v) => '$symbol${_amountFmt.format(v)}';
    final bizName = ((biz['name'] as String?) ?? 'My Business').trim();

    final theme = pw.ThemeData.withFont(
      base: _regular!,
      bold: _bold!,
      italic: _regular!,
      boldItalic: _bold!,
      fontFallback: [_regular!],
    );
    final doc = pw.Document(theme: theme);

    final totalValue = items.fold<double>(0, (s, i) => s + i.stockValue);
    final totalUnits = items.fold<double>(0, (s, i) => s + i.currentStock);

    pw.Widget cell(String text,
            {pw.TextAlign align = pw.TextAlign.left, bool bold = false}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(text,
              textAlign: align,
              style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        );

    pw.TableRow row(List<pw.Widget> cells, {PdfColor? color}) => pw.TableRow(
          decoration:
              color == null ? null : pw.BoxDecoration(color: color),
          children: cells,
        );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(24),
        header: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(bizName,
                style:
                    pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 2),
            pw.Text('Inventory Stock Report',
                style: pw.TextStyle(fontSize: 12, color: PdfColors.grey700)),
            pw.Text('Generated ${_dateFmt.format(DateTime.now())}',
                style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600)),
            pw.SizedBox(height: 10),
          ],
        ),
        build: (_) => [
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            columnWidths: const {
              0: pw.FlexColumnWidth(3.2),
              1: pw.FlexColumnWidth(2),
              2: pw.FlexColumnWidth(1.4),
              3: pw.FlexColumnWidth(1.2),
              4: pw.FlexColumnWidth(1.8),
              5: pw.FlexColumnWidth(1.8),
            },
            children: [
              row([
                cell('Item', bold: true),
                cell('Category', bold: true),
                cell('Stock', align: pw.TextAlign.right, bold: true),
                cell('Unit', bold: true),
                cell('Purchase', align: pw.TextAlign.right, bold: true),
                cell('Value', align: pw.TextAlign.right, bold: true),
              ], color: PdfColors.grey300),
              for (final it in items)
                row([
                  cell(it.name),
                  cell(it.categoryName ?? '—'),
                  cell(_qtyFmt.format(it.currentStock),
                      align: pw.TextAlign.right),
                  cell(it.baseUnit ?? '—'),
                  cell(money(it.basePurchasePrice), align: pw.TextAlign.right),
                  cell(money(it.stockValue), align: pw.TextAlign.right),
                ]),
              row([
                cell('Total (${items.length} items)', bold: true),
                cell(''),
                cell(_qtyFmt.format(totalUnits),
                    align: pw.TextAlign.right, bold: true),
                cell(''),
                cell(''),
                cell(money(totalValue), align: pw.TextAlign.right, bold: true),
              ], color: PdfColors.grey200),
            ],
          ),
        ],
      ),
    );

    return doc.save();
  }
}
