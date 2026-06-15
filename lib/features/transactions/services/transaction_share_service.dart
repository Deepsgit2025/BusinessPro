import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../models/transaction.dart';
import '../models/transaction_item.dart';
import 'invoice_pdf_service.dart';

/// How a saved transaction document should be shared.
enum ShareFormat { image, pdf }

/// Shares a saved transaction document (sale invoice, payment-in, estimate,
/// delivery challan, sale return) as either a rendered image or a PDF.
///
/// Call [share] after the document has been persisted. It presents the
/// "Share transaction" chooser (Image / PDF) unless the user has previously
/// ticked "Make this as default", in which case it shares in that format
/// straight away. The PDF is built once via [InvoicePdfService] and the image
/// is a raster of its first page, so both formats show the exact same document.
class TransactionShareService {
  TransactionShareService._();

  /// Entry point. Builds the document, resolves the desired format (stored
  /// default or a fresh choice from the bottom sheet), and shares it.
  /// Returns silently if the user dismisses the chooser.
  static Future<void> share({
    required BuildContext context,
    required Transaction transaction,
    required List<TransactionItem> items,
  }) async {
    final stored = await DatabaseHelper.getSettingStr(
      AppStrings.kDefaultShareFormat,
    );
    ShareFormat? format = _parse(stored);

    if (format == null) {
      if (!context.mounted) return;
      format = await _pickFormat(context);
      if (format == null) return; // dismissed
    }

    // Sharing always sends the single Original copy for a sale invoice (the
    // 3-copy set is print-only); other document types are unlabelled.
    final bytes = await InvoicePdfService.build(
      transaction: transaction,
      items: items,
      copyLabel: transaction.transactionType == TxnTypes.sale
          ? InvoicePdfService.copyLabels.first
          : null,
    );
    final baseName = transaction.transactionNumber.replaceAll(
      RegExp(r'[^\w\-]'),
      '_',
    );

    if (format == ShareFormat.pdf) {
      await _sharePdf(bytes, baseName);
    } else {
      await _shareImage(bytes, baseName);
    }
  }

  static ShareFormat? _parse(String raw) => switch (raw) {
        'image' => ShareFormat.image,
        'pdf' => ShareFormat.pdf,
        _ => null,
      };

  // ── Share sheet ─────────────────────────────────────────────────────────────

  static Future<ShareFormat?> _pickFormat(BuildContext context) {
    return showModalBottomSheet<ShareFormat>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => const _ShareSheet(),
    );
  }

  // ── Output ──────────────────────────────────────────────────────────────────

  static Future<void> _sharePdf(Uint8List bytes, String baseName) async {
    await Printing.sharePdf(bytes: bytes, filename: '$baseName.pdf');
  }

  /// Rasterises the first PDF page to a PNG and shares it via the system sheet
  /// (so the user can pick WhatsApp, etc.).
  static Future<void> _shareImage(Uint8List pdfBytes, String baseName) async {
    Uint8List? png;
    await for (final page in Printing.raster(pdfBytes, dpi: 200)) {
      png = await page.toPng();
      break; // single-page documents; first page is the receipt/invoice
    }
    if (png == null) {
      // Fall back to PDF if rasterising produced nothing.
      await _sharePdf(pdfBytes, baseName);
      return;
    }

    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, '$baseName.png'));
    await file.writeAsBytes(png);
    await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
  }
}

/// The "Share transaction" bottom sheet with Image / PDF choices and a
/// "Make this as default" checkbox. Pops with the chosen [ShareFormat] (and
/// persists it as the default first when the box is ticked), or `null` if
/// dismissed.
class _ShareSheet extends StatefulWidget {
  const _ShareSheet();

  @override
  State<_ShareSheet> createState() => _ShareSheetState();
}

class _ShareSheetState extends State<_ShareSheet> {
  bool _makeDefault = false;

  Future<void> _choose(ShareFormat format) async {
    if (_makeDefault) {
      await DatabaseHelper.setSetting(
        AppStrings.kDefaultShareFormat,
        format == ShareFormat.image ? 'image' : 'pdf',
      );
    }
    if (mounted) Navigator.pop(context, format);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Share transaction',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: _ShareButton(
                    label: 'Share as Image',
                    icon: Icons.image_outlined,
                    background: AppColors.expense,
                    foreground: Colors.white,
                    iconColor: AppColors.expense,
                    onTap: () => _choose(ShareFormat.image),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _ShareButton(
                    label: 'Share as PDF',
                    icon: Icons.picture_as_pdf_outlined,
                    background: AppColors.partial.withValues(alpha: 0.12),
                    foreground: AppColors.textPrimary,
                    iconColor: AppColors.partial,
                    onTap: () => _choose(ShareFormat.pdf),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () => setState(() => _makeDefault = !_makeDefault),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: _makeDefault,
                      onChanged: (v) =>
                          setState(() => _makeDefault = v ?? false),
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                    ),
                    const SizedBox(width: 4),
                    const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Make this as default',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w500)),
                        SizedBox(height: 2),
                        Text(
                          'To change later go to transaction settings*',
                          style: TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color background;
  final Color foreground;
  final Color iconColor;
  final VoidCallback onTap;

  const _ShareButton({
    required this.label,
    required this.icon,
    required this.background,
    required this.foreground,
    required this.iconColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 30,
                height: 30,
                decoration:
                    const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                child: Icon(icon, size: 18, color: iconColor),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: foreground),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
