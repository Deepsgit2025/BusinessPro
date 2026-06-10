import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/database/database_helper.dart';

/// A single report rendered as a simple title + column headers + rows table,
/// ready to be turned into a PDF or CSV. Cell values are pre-formatted strings
/// (currency/date formatting happens on the report screen so the export matches
/// exactly what the user sees). Optional [summary] lines (label → value) print
/// under the table.
class ReportData {
  final String title;
  final String subtitle; // e.g. the date-range label
  final List<String> headers;
  final List<List<String>> rows;
  final List<MapEntry<String, String>> summary;
  /// Column alignment hints (true ⇒ right-align, for numeric columns).
  final List<bool> rightAlign;

  ReportData({
    required this.title,
    required this.subtitle,
    required this.headers,
    required this.rows,
    this.summary = const [],
    List<bool>? rightAlign,
  }) : rightAlign =
            rightAlign ?? List<bool>.filled(headers.length, false);
}

/// Builds and shares report exports. Reused across all ten report screens via a
/// uniform [ReportData] payload — the SQL and screen-specific formatting stay in
/// the report screens, this layer only renders and shares.
class ReportExportService {
  ReportExportService._();

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

  // ── PDF ────────────────────────────────────────────────────────────────────

  static Future<Uint8List> buildPdf(ReportData data) async {
    await _ensureFonts();
    final biz = await DatabaseHelper.getBusiness() ?? const {};
    final bizName = ((biz['name'] as String?) ?? 'My Business').trim();

    final theme = pw.ThemeData.withFont(
      base: _regular!,
      bold: _bold!,
      italic: _regular!,
      boldItalic: _bold!,
      fontFallback: [_regular!],
    );
    final doc = pw.Document(theme: theme);

    final headerStyle = pw.TextStyle(
        fontSize: 8, fontWeight: pw.FontWeight.bold, color: PdfColors.white);
    const cellStyle = pw.TextStyle(fontSize: 8);

    pw.Widget cell(String text, {pw.TextStyle style = cellStyle, bool right = false}) =>
        pw.Container(
          alignment: right ? pw.Alignment.centerRight : pw.Alignment.centerLeft,
          padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          child: pw.Text(text, style: style),
        );

    final tableRows = <pw.TableRow>[
      pw.TableRow(
        decoration: const pw.BoxDecoration(color: PdfColors.blue800),
        children: [
          for (var i = 0; i < data.headers.length; i++)
            cell(data.headers[i], style: headerStyle, right: data.rightAlign[i]),
        ],
      ),
      for (var r = 0; r < data.rows.length; r++)
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: r.isEven ? PdfColors.white : PdfColors.grey50,
          ),
          children: [
            for (var i = 0; i < data.rows[r].length; i++)
              cell(data.rows[r][i], right: data.rightAlign[i]),
          ],
        ),
    ];

    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.all(28),
      build: (context) => [
        pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(bizName,
                    style: pw.TextStyle(
                        fontSize: 14, fontWeight: pw.FontWeight.bold)),
                pw.Text(data.title,
                    style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                        color: PdfColors.blue800)),
                if (data.subtitle.isNotEmpty)
                  pw.Text(data.subtitle,
                      style: const pw.TextStyle(
                          fontSize: 9, color: PdfColors.grey700)),
              ],
            ),
            pw.Text('Generated ${_dateFmt.format(DateTime.now())}',
                style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600)),
          ],
        ),
        pw.SizedBox(height: 12),
        if (data.rows.isEmpty)
          pw.Text('No data for the selected period.',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700))
        else
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
            children: tableRows,
          ),
        if (data.summary.isNotEmpty) ...[
          pw.SizedBox(height: 12),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.end,
            children: [
              pw.Container(
                width: 240,
                child: pw.Column(
                  children: [
                    for (final s in data.summary)
                      pw.Padding(
                        padding: const pw.EdgeInsets.symmetric(vertical: 2),
                        child: pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            pw.Text(s.key,
                                style: pw.TextStyle(
                                    fontSize: 9,
                                    fontWeight: pw.FontWeight.bold)),
                            pw.Text(s.value,
                                style: pw.TextStyle(
                                    fontSize: 9,
                                    fontWeight: pw.FontWeight.bold)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ],
        pw.SizedBox(height: 24),
        pw.Center(
          child: pw.Text('Powered by BusinessPro',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey)),
        ),
      ],
    ));

    return doc.save();
  }

  /// Builds the report PDF and opens the system share sheet.
  static Future<void> sharePdf(ReportData data) async {
    final bytes = await buildPdf(data);
    await Printing.sharePdf(bytes: bytes, filename: '${_fileBase(data.title)}.pdf');
  }

  // ── CSV ──────────────────────────────────────────────────────────────────

  static String buildCsv(ReportData data) {
    final buf = StringBuffer();
    buf.writeln(_csvRow(data.headers));
    for (final row in data.rows) {
      buf.writeln(_csvRow(row));
    }
    if (data.summary.isNotEmpty) {
      buf.writeln();
      for (final s in data.summary) {
        buf.writeln(_csvRow([s.key, s.value]));
      }
    }
    return buf.toString();
  }

  /// Writes the report to a temp CSV file and opens the system share sheet.
  static Future<void> shareCsv(ReportData data) async {
    final csv = buildCsv(data);
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, '${_fileBase(data.title)}.csv'));
    await file.writeAsString(csv);
    await SharePlus.instance.share(
      ShareParams(files: [XFile(file.path)], text: data.title),
    );
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static String _csvRow(List<String> cells) =>
      cells.map(_csvCell).join(',');

  /// Quotes a CSV cell when it contains a comma, quote, or newline; doubles
  /// embedded quotes per RFC 4180.
  static String _csvCell(String value) {
    if (value.contains(',') || value.contains('"') || value.contains('\n')) {
      return '"${value.replaceAll('"', '""')}"';
    }
    return value;
  }

  static String _fileBase(String title) {
    final clean = title.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_');
    final stamp = DateFormat('yyyyMMdd').format(DateTime.now());
    return 'BusinessPro_${clean}_$stamp';
  }
}
