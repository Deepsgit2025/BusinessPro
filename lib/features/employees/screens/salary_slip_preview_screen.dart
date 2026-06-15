import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../services/whatsapp/whatsapp_invoice_service.dart';
import '../models/employee.dart';
import '../models/salary_payment.dart';

/// Full-screen preview of a generated salary slip PDF, with the same three-button
/// share row as the invoice preview (WhatsApp / Share PDF / Print).
///
/// The PDF [pdfBytes] are built by the caller (see [SalarySlipPdfService.build]).
/// Rather than embedding `PdfPreview` (whose native raster surface rendered the
/// slip all-black on Android), the pages are rasterised once via [Printing.raster]
/// — the same path the WhatsApp/share flows use — and shown as plain images on a
/// white background. Sharing reuses [WhatsAppInvoiceService] so the Windows
/// share-flyout anchoring (`sharePositionOrigin`) is handled the same way as for
/// invoices.
class SalarySlipPreviewScreen extends StatelessWidget {
  final Uint8List pdfBytes;
  final Employee employee;
  final SalaryPayment payment;
  final String monthLabel;

  /// Message used as the WhatsApp/share caption.
  final String message;

  const SalarySlipPreviewScreen({
    super.key,
    required this.pdfBytes,
    required this.employee,
    required this.payment,
    required this.monthLabel,
    required this.message,
  });

  String get _baseName => 'Salary-${payment.paymentMonth}-${employee.name}';

  /// Anchors the native Windows/iPad share flyout — without it the flyout can
  /// open off-screen and lock the window.
  Rect? _origin(BuildContext context) =>
      WhatsAppInvoiceService.originFromContext(context);

  Future<void> _sendViaWhatsApp(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final origin = _origin(context);
    // Rasterise the first page to a PNG (same path as the invoice image flow).
    Uint8List? png;
    try {
      await for (final page in Printing.raster(pdfBytes, dpi: 200)) {
        png = await page.toPng();
        break;
      }
    } catch (_) {
      png = null;
    }
    if (png == null) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Could not render salary slip')));
      return;
    }
    final result = await WhatsAppInvoiceService.shareInvoiceImage(
      pngBytes: png,
      baseName: _baseName,
      phone: employee.phone,
      message: message,
      sharePositionOrigin: origin,
    );
    if (result.error != null) {
      messenger.showSnackBar(SnackBar(content: Text(result.error!)));
    }
  }

  Future<void> _sharePdf(BuildContext context) async {
    await WhatsAppInvoiceService.shareInvoicePdf(
      pdfBytes: pdfBytes,
      baseName: _baseName,
      sharePositionOrigin: _origin(context),
    );
  }

  Future<void> _print() async {
    await Printing.layoutPdf(onLayout: (_) async => pdfBytes);
  }

  /// Rasterises every page of the slip to a PNG at 2x screen density so the
  /// preview is crisp. Runs once; the result feeds the [_PdfImageView].
  Future<List<Uint8List>> _rasterPages() async {
    final pages = <Uint8List>[];
    await for (final page in Printing.raster(pdfBytes, dpi: 144)) {
      pages.add(await page.toPng());
    }
    return pages;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Salary Slip'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(20),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 6, left: 16, right: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${employee.name} · $monthLabel',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
          ),
        ),
      ),
      body: _PdfImageView(load: _rasterPages),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.share, color: Color(0xFF25D366)),
                  label: const Text('WhatsApp'),
                  onPressed: () => _sendViaWhatsApp(context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.picture_as_pdf),
                  label: const Text('Share PDF'),
                  onPressed: () => _sharePdf(context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                  ),
                  icon: const Icon(Icons.print),
                  label: const Text('Print'),
                  onPressed: _print,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders rasterised PDF pages as a scrollable list of images on a neutral grey
/// backdrop, each page sitting on a white card. Replaces `PdfPreview` here to
/// dodge the all-black native raster surface seen with the salary slip.
class _PdfImageView extends StatelessWidget {
  final Future<List<Uint8List>> Function() load;
  const _PdfImageView({required this.load});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF525659), // standard PDF-viewer grey
      child: FutureBuilder<List<Uint8List>>(
        future: load(),
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text('Could not render slip:\n${snap.error}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70)),
            );
          }
          final pages = snap.data ?? const [];
          if (pages.isEmpty) {
            return const Center(
              child: Text('Nothing to preview',
                  style: TextStyle(color: Colors.white70)),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: pages.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (_, i) => DecoratedBox(
              decoration: const BoxDecoration(
                color: Colors.white,
                boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 6)],
              ),
              child: Image.memory(pages[i], fit: BoxFit.fitWidth),
            ),
          );
        },
      ),
    );
  }
}
