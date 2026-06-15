import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../features/transactions/models/transaction.dart';
import '../../features/transactions/models/transaction_item.dart';
import '../../features/transactions/services/invoice_pdf_service.dart';

/// Outcome of a WhatsApp share attempt.
///
/// The image is always handed to the system share sheet, so [success] means the
/// sheet opened. [whatsappNotInstalled] is informational: we could not surface a
/// WhatsApp chat directly, but the image was still shared (the user can pick any
/// target). [error] carries an unexpected failure message.
class WhatsAppResult {
  final bool success;
  final String? error;
  final bool whatsappNotInstalled;

  const WhatsAppResult._({
    required this.success,
    this.error,
    this.whatsappNotInstalled = false,
  });

  factory WhatsAppResult.success() => const WhatsAppResult._(success: true);
  factory WhatsAppResult.error(String e) =>
      WhatsAppResult._(success: false, error: e);
  factory WhatsAppResult.whatsappNotInstalled() =>
      const WhatsAppResult._(success: true, whatsappNotInstalled: true);
}

/// Builds an invoice as a PNG image and shares it to WhatsApp (personal mode).
///
/// IMPORTANT: nothing here is persisted to the database. The PNG only ever lives
/// as an in-memory [Uint8List] and as a temporary file under
/// [getTemporaryDirectory] (OS-managed cleanup) — never a DB column.
///
/// The image is produced by rasterising the first page of the existing invoice
/// PDF ([InvoicePdfService.build]) via [Printing.raster], exactly as the
/// "Share as Image" flow does. This works identically on Android and Windows, so
/// no platform-specific image code (or extra packages) is required.
///
/// WhatsApp's deep links cannot carry both a pre-filled number AND a file
/// attachment, so the image is always shared through the system share sheet. On
/// Android we additionally try to surface the target chat via the `whatsapp://`
/// scheme; the number pre-fill is best-effort only.
class WhatsAppInvoiceService {
  WhatsAppInvoiceService._();

  /// Platform channel to the Android native WhatsApp intent (see MainActivity).
  static const _channel = MethodChannel('com.businesspro.app/whatsapp');

  /// Renders the invoice to a PNG. Returns `null` if rendering fails so the UI
  /// can degrade gracefully (e.g. offer "Share as PDF" instead).
  static Future<Uint8List?> buildInvoicePng({
    required Transaction transaction,
    required List<TransactionItem> items,
  }) async {
    try {
      final pdfBytes = await InvoicePdfService.build(
        transaction: transaction,
        items: items,
        copyLabel: _saleCopyLabel(transaction),
      );
      await for (final page in Printing.raster(pdfBytes, dpi: 200)) {
        return await page.toPng();
      }
    } catch (_) {
      // Fall through to null — caller handles a failed render.
    }
    return null;
  }

  /// Builds the invoice PDF bytes (for the "Share as PDF" fallback).
  static Future<Uint8List> buildInvoicePdf({
    required Transaction transaction,
    required List<TransactionItem> items,
  }) {
    return InvoicePdfService.build(
      transaction: transaction,
      items: items,
      copyLabel: _saleCopyLabel(transaction),
    );
  }

  /// WhatsApp / share always sends the single "ORIGINAL FOR RECIPIENT" copy for
  /// a sale invoice; other document types are unlabelled.
  static String? _saleCopyLabel(Transaction t) =>
      t.transactionType == TxnTypes.sale
          ? InvoicePdfService.copyLabels.first
          : null;

  /// Saves [pngBytes] to a temp file and shares it through the system share
  /// sheet, with [message] as the caption.
  ///
  /// On Android, when [phone] is given, we first try a native WhatsApp intent
  /// (see MainActivity) that opens **directly in that contact's chat** with the
  /// image attached — so the user only taps Send. If WhatsApp isn't installed or
  /// the intent can't resolve, we fall back to the generic share sheet.
  ///
  /// We never fire a `whatsapp://send?...&text=` deep link: it pre-fills text but
  /// CANNOT carry the image, so racing it against a file share delivers a
  /// text-only message with no invoice. The native ACTION_SEND intent below is
  /// the only way to pre-target the number AND attach the image together.
  ///
  /// [sharePositionOrigin] anchors the native Windows/iPad share sheet to a
  /// screen rect. On Windows this is REQUIRED — without an anchor the
  /// DataTransferManager flyout can open off-screen and lock the window. Pass
  /// the global rect of the tapped button (see [originFromContext]).
  static Future<WhatsAppResult> shareInvoiceImage({
    required Uint8List pngBytes,
    required String baseName,
    String? phone,
    required String message,
    Rect? sharePositionOrigin,
  }) async {
    try {
      final file = await _writeTempPng(pngBytes, baseName);

      // Android: try opening the exact WhatsApp chat with the image attached.
      if (Platform.isAndroid && phone != null && phone.trim().isNotEmpty) {
        final opened = await _sendDirectAndroid(
          path: file.path,
          phone: _normalizePhone(phone),
          caption: message,
        );
        if (opened) return WhatsAppResult.success();
        // Could not target WhatsApp → fall through to the generic share sheet.
      }

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          text: message,
          sharePositionOrigin: sharePositionOrigin,
        ),
      );
      // On Android with a number we wanted to pre-target but couldn't, flag it.
      if (Platform.isAndroid && phone != null && phone.trim().isNotEmpty) {
        return WhatsAppResult.whatsappNotInstalled();
      }
      return WhatsAppResult.success();
    } catch (e) {
      return WhatsAppResult.error(e.toString());
    }
  }

  /// Invokes the native intent. Returns true if WhatsApp opened in the chat.
  static Future<bool> _sendDirectAndroid({
    required String path,
    required String phone,
    required String caption,
  }) async {
    try {
      final ok = await _channel.invokeMethod<bool>('sendImageToNumber', {
        'path': path,
        'phone': phone,
        'caption': caption,
      });
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Digits-only number with India's country code (91) when none is present, as
  /// WhatsApp's jid requires (`<digits>@s.whatsapp.net`).
  static String _normalizePhone(String phone) {
    var clean = phone.replaceAll(RegExp(r'[^\d+]'), '');
    if (!clean.startsWith('+') && !clean.startsWith('91')) {
      clean = '91$clean';
    }
    return clean.replaceAll('+', '');
  }

  /// Shares the invoice PDF via the system sheet (alternative to the image).
  static Future<void> shareInvoicePdf({
    required Uint8List pdfBytes,
    required String baseName,
    Rect? sharePositionOrigin,
  }) async {
    await Printing.sharePdf(
      bytes: pdfBytes,
      filename: '$baseName.pdf',
      // Anchor the Windows/iPad share sheet (see shareInvoiceImage).
      bounds: sharePositionOrigin,
    );
  }

  /// Computes the global screen rect of the widget behind [context], for use as
  /// [shareInvoiceImage]'s `sharePositionOrigin`. Returns null if unavailable.
  static Rect? originFromContext(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    return topLeft & box.size;
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static Future<File> _writeTempPng(Uint8List bytes, String baseName) async {
    final dir = await getTemporaryDirectory();
    final safe = baseName.replaceAll(RegExp(r'[^\w\-]'), '_');
    final file = File(p.join(dir.path, '$safe.png'));
    await file.writeAsBytes(bytes);
    return file;
  }
}
