import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../../core/database/database_helper.dart';
import '../models/employee.dart';
import '../models/salary_payment.dart';

/// Builds a one-page A4 salary slip PDF for a recorded [SalaryPayment].
///
/// Mirrors [InvoicePdfService]'s font handling: the default PDF font lacks the
/// rupee glyph, so the bundled Noto Sans family is loaded and used for all text.
class SalarySlipPdfService {
  SalarySlipPdfService._();

  static final _amountFmt = NumberFormat('#,##,##0.00', 'en_IN');
  static final _dateFmt = DateFormat('dd MMM yyyy');

  static pw.Font? _regular;
  static pw.Font? _bold;

  static Future<void> _ensureFonts() async {
    if (_regular != null && _bold != null) return;
    final reg = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    final bold = await rootBundle.load('assets/fonts/NotoSans-Bold.ttf');
    _regular = pw.Font.ttf(reg);
    _bold = pw.Font.ttf(bold);
  }

  static String _monthLabel(String monthKey) {
    final parts = monthKey.split('-');
    if (parts.length != 2) return monthKey;
    final y = int.tryParse(parts[0]) ?? 2000;
    final m = int.tryParse(parts[1]) ?? 1;
    return DateFormat('MMMM yyyy').format(DateTime(y, m));
  }

  /// Renders the salary slip. The employee's advance figures (opening / closing)
  /// are derived from the current running totals and this payment's credited
  /// amount; pass the [employee] as loaded *before* the payment was recorded for
  /// the opening figure, or after — closing = current outstanding either way is
  /// computed from the snapshot on [payment].
  static Future<Uint8List> build({
    required Employee employee,
    required SalaryPayment payment,
    double openingAdvance = 0,
  }) async {
    await _ensureFonts();
    final biz = await DatabaseHelper.getBusiness() ?? const {};
    final symbol = (biz['currency_symbol'] as String?) ?? '₹';
    String money(num v) => '$symbol${_amountFmt.format(v)}';

    final theme = pw.ThemeData.withFont(
      base: _regular!,
      bold: _bold!,
      italic: _regular!,
      boldItalic: _bold!,
      fontFallback: [_regular!],
    );
    final doc = pw.Document(theme: theme);

    final bizName = ((biz['name'] as String?) ?? 'My Business').trim();
    final bizAddr = [
      (biz['address_line1'] as String?)?.trim(),
      (biz['city'] as String?)?.trim(),
    ].where((s) => s != null && s.isNotEmpty).join(', ');
    final bizPhone = (biz['phone'] as String?)?.trim() ?? '';

    final closingAdvance = openingAdvance - payment.advanceCredited;

    doc.addPage(
      pw.Page(
        pageTheme: pw.PageTheme(
          pageFormat: PdfPageFormat.a4,
          theme: theme,
          margin: const pw.EdgeInsets.all(32),
          // Paint the whole page white. Without this the PDF background is
          // transparent, which dark-mode PDF viewers and the shared PNG raster
          // (the WhatsApp image) render as black. Mirrors InvoicePdfService.
          buildBackground: (context) => pw.FullPage(
            ignoreMargins: true,
            child: pw.Container(color: PdfColors.white),
          ),
        ),
        build: (context) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            // Header.
            pw.Center(
              child: pw.Column(children: [
                pw.Text('SALARY SLIP',
                    style: pw.TextStyle(
                        fontSize: 18,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.blue800)),
                pw.SizedBox(height: 4),
                pw.Text(bizName,
                    style: pw.TextStyle(
                        fontSize: 13, fontWeight: pw.FontWeight.bold)),
                if (bizAddr.isNotEmpty || bizPhone.isNotEmpty)
                  pw.Text(
                      [bizAddr, if (bizPhone.isNotEmpty) 'Ph: $bizPhone']
                          .where((s) => s.isNotEmpty)
                          .join('  ·  '),
                      style: const pw.TextStyle(fontSize: 9)),
              ]),
            ),
            pw.SizedBox(height: 14),
            pw.Divider(color: PdfColors.grey400),
            // Employee + month meta.
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                _kv('Employee', employee.name),
                _kv('Month', _monthLabel(payment.paymentMonth)),
              ],
            ),
            pw.SizedBox(height: 2),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                _kv('Phone', employee.phone ?? '—'),
                _kv('Date', _dateFmt.format(
                    DateTime.tryParse(payment.paymentDate) ?? DateTime.now())),
              ],
            ),
            pw.SizedBox(height: 12),
            _sectionTitle('Attendance'),
            _line('Full days', '${payment.fullDays}  @ ${money(employee.dailyPay)}/day',
                money(payment.fullDays * employee.dailyPay)),
            _line('Half days',
                '${payment.halfDays}  @ ${money(employee.dailyPay / 2)}/day',
                money(payment.halfDays * employee.dailyPay / 2)),
            _line('Absent days', '${payment.absentDays}', money(0)),
            // Overtime is a signed net (negative = early-leave deduction).
            // Show whenever non-zero; a negative amount reads as a deduction.
            if (payment.overtimeHours != 0)
              _line(
                  payment.overtimeHours < 0 ? 'Overtime (early leave)' : 'Overtime',
                  '${_plain(payment.overtimeHours)} hrs @ ${money(employee.overtimeRate)}/hr',
                  money(payment.overtimeAmount)),
            pw.Divider(color: PdfColors.grey300),
            _totalRow('Gross Salary', money(payment.salaryEarned)),
            pw.SizedBox(height: 12),
            _sectionTitle('Payment Details'),
            _totalRow('Cash Paid', money(payment.cashPaid), bold: false),
            _totalRow('Credited to Advance', money(payment.advanceCredited),
                bold: false),
            _totalRow('Remaining', money(payment.remaining), bold: false),
            pw.SizedBox(height: 12),
            _sectionTitle('Advance'),
            _totalRow('Opening Outstanding', money(openingAdvance),
                bold: false),
            _totalRow('Credited this month', money(payment.advanceCredited),
                bold: false),
            _totalRow('Closing Outstanding', money(closingAdvance)),
            pw.Spacer(),
            pw.Center(
              child: pw.Text('Thank you for your hard work!',
                  style: const pw.TextStyle(
                      fontSize: 10, color: PdfColors.grey700)),
            ),
            pw.SizedBox(height: 4),
            pw.Center(
              child: pw.Text('Powered by BusinessPro',
                  style: const pw.TextStyle(
                      fontSize: 8, color: PdfColors.grey500)),
            ),
          ],
        ),
      ),
    );

    return doc.save();
  }

  static pw.Widget _kv(String k, String v) => pw.RichText(
        text: pw.TextSpan(children: [
          pw.TextSpan(
              text: '$k: ',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          pw.TextSpan(
              text: v,
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
        ]),
      );

  static pw.Widget _sectionTitle(String t) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 4),
        child: pw.Text(t.toUpperCase(),
            style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.blue800,
                letterSpacing: 0.5)),
      );

  static pw.Widget _line(String label, String detail, String amount) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Expanded(
              child: pw.RichText(
                text: pw.TextSpan(children: [
                  pw.TextSpan(
                      text: '$label   ',
                      style: const pw.TextStyle(fontSize: 10)),
                  pw.TextSpan(
                      text: detail,
                      style: const pw.TextStyle(
                          fontSize: 9, color: PdfColors.grey700)),
                ]),
              ),
            ),
            pw.Text(amount, style: const pw.TextStyle(fontSize: 10)),
          ],
        ),
      );

  static pw.Widget _totalRow(String label, String amount, {bool bold = true}) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(label,
                style: pw.TextStyle(
                    fontSize: bold ? 11 : 10,
                    fontWeight:
                        bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
            pw.Text(amount,
                style: pw.TextStyle(
                    fontSize: bold ? 11 : 10,
                    fontWeight:
                        bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
          ],
        ),
      );

  static String _plain(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();
}
