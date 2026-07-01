import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../parties/repositories/party_repository.dart';
import '../../../core/database/database_helper.dart';
import '../../../services/printer/printer_manager.dart';
import '../../../services/printer/printer_providers.dart';
import '../models/transaction.dart';
import '../providers/transaction_providers.dart';
import '../widgets/print_copies_sheet.dart';
import 'invoice_pdf_service.dart';

/// Shared document (PDF / print / share) actions for a saved transaction.
///
/// This is the single source of truth for "turn a [TransactionDetail] into a
/// PDF and open / print / share it", used both by the document detail screen's
/// ⋮ menu and by the inline Print / Share buttons on a [TransactionCard]. The
/// logic was lifted verbatim out of the detail screen so the two surfaces behave
/// identically (e.g. a sale invoice still prints the 3-copy Format-1 set after
/// the copy-picker sheet).
class DocumentActions {
  DocumentActions._();

  /// The document types that have a PDF representation (everything shown on the
  /// shared detail screen). Cash rows — `expense` / `other_income` — have no PDF
  /// and so get no Print / Share affordance.
  static const pdfTypes = {
    TxnTypes.sale,
    TxnTypes.estimate,
    TxnTypes.deliveryChallan,
    TxnTypes.saleReturn,
    TxnTypes.saleOrder,
    TxnTypes.paymentIn,
    TxnTypes.paymentOut,
    TxnTypes.purchase,
    TxnTypes.purchaseReturn,
    TxnTypes.purchaseOrder,
  };

  static bool canPdf(String transactionType) =>
      pdfTypes.contains(transactionType);

  // ── Card glue: load the detail by id, then act ──────────────────────────────
  // A [TransactionCard] only holds a bare [Transaction] (no line items), so
  // these load the full [TransactionDetail] before building the PDF. They share
  // the same loader [transactionDetailProvider] uses, so a card and the detail
  // screen produce byte-identical PDFs.

  /// Loads the detail for [txn] and runs the smart print path (sale invoices get
  /// the 3-copy picker). Surfaces a SnackBar if the record can't be loaded.
  static Future<void> printById(
      BuildContext context, WidgetRef ref, Transaction txn) async {
    final detail = await _loadDetail(context, ref, txn);
    if (detail == null || !context.mounted) return;
    await printPdf(context, detail, challan: false);
  }

  /// Loads the detail for [txn] and opens the OS share sheet with its PDF.
  static Future<void> shareById(
      BuildContext context, WidgetRef ref, Transaction txn) async {
    final detail = await _loadDetail(context, ref, txn);
    if (detail == null) return;
    await sharePdf(detail, challan: false);
  }

  static Future<TransactionDetail?> _loadDetail(
      BuildContext context, WidgetRef ref, Transaction txn) async {
    try {
      final detail =
          await ref.read(transactionDetailProvider(txn.id!).future);
      if (detail == null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not load this document')));
      }
      return detail;
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not load this document')));
      }
      return null;
    }
  }

  // ── PDF plumbing (invoice + delivery challan share the builder) ─────────────

  /// Builds the PDF bytes from an already-loaded [detail]. When [challan] is
  /// true it renders the delivery-challan variant (no prices, 'DELIVERY CHALLAN'
  /// title).
  static Future<Uint8List> buildPdf(TransactionDetail detail,
      {required bool challan}) {
    final t = detail.transaction;
    return InvoicePdfService.build(
      transaction: t,
      items: detail.items,
      docTitleOverride: challan ? 'DELIVERY CHALLAN' : null,
      hidePrices: challan,
      // A shared / opened / saved sale invoice carries the single Original copy
      // label (the 3-copy set is print-only).
      copyLabel: !challan && t.transactionType == TxnTypes.sale
          ? InvoicePdfService.copyLabels.first
          : null,
    );
  }

  static String fileName(TransactionDetail detail, {required bool challan}) {
    final base = detail.transaction.transactionNumber
        .replaceAll(RegExp(r'[^\w\-]'), '_');
    return challan ? '${base}_DC.pdf' : '$base.pdf';
  }

  /// Opens the in-app PDF preview for the document (or its delivery challan).
  static Future<void> openPdf(BuildContext context, TransactionDetail detail,
      {required bool challan}) async {
    final title = challan
        ? '${detail.transaction.transactionNumber} (Challan)'
        : detail.transaction.transactionNumber;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: PdfPreview(
            build: (_) => buildPdf(detail, challan: challan),
            canChangePageFormat: false,
            canChangeOrientation: false,
            pdfFileName: fileName(detail, challan: challan),
          ),
        ),
      ),
    );
  }

  /// Shares the PDF via the OS share sheet.
  static Future<void> sharePdf(TransactionDetail detail,
      {required bool challan}) async {
    final bytes = await buildPdf(detail, challan: challan);
    await Printing.sharePdf(
        bytes: bytes, filename: fileName(detail, challan: challan));
  }

  /// Prints the document. A sale invoice prints as the 3-copy Format 1 set after
  /// the user picks copies; everything else prints the single-page PDF.
  /// [context] is required for the copy-selection sheet (sale invoices only).
  static Future<void> printPdf(BuildContext? context, TransactionDetail detail,
      {required bool challan}) async {
    final t = detail.transaction;
    if (!challan && t.transactionType == TxnTypes.sale && context != null) {
      final labels = await PrintCopiesSheet.show(context);
      if (labels == null) return; // dismissed
      if (labels.isEmpty) return;
      await Printing.layoutPdf(
        onLayout: (_) => InvoicePdfService.buildAllCopies(
          transaction: t,
          items: detail.items,
          labels: labels,
        ),
      );
      return;
    }
    await Printing.layoutPdf(onLayout: (_) => buildPdf(detail, challan: challan));
  }

  /// Print to a thermal (ESC/POS) printer. On Windows with thermal disabled,
  /// [PrinterManager] throws [UsePdfFallback] and we route to the A4 PDF path.
  static Future<void> printThermal(
      BuildContext context, WidgetRef ref, TransactionDetail detail) async {
    final messenger = ScaffoldMessenger.of(context);
    final t = detail.transaction;
    try {
      final biz = await DatabaseHelper.getBusiness() ?? <String, dynamic>{};
      final party = t.partyId != null
          ? await PartyRepository().getById(t.partyId!)
          : null;
      final paymentModeName =
          detail.payments.isNotEmpty ? detail.payments.first.modeName : null;

      await ref.read(printerManagerProvider).printTransaction(
            transaction: t,
            items: detail.items,
            business: biz,
            party: party,
            paymentModeName: paymentModeName,
          );
      messenger.showSnackBar(
          const SnackBar(content: Text('Printed successfully ✓')));
    } on UsePdfFallback {
      // Windows, thermal not default → use the existing A4 PDF print.
      if (!context.mounted) return;
      await printPdf(context, detail, challan: false);
    } on NoDefaultPrinter {
      if (!context.mounted) return;
      await _printerError(context,
          title: 'No printer set up',
          message: 'Go to Settings → Printer Settings to connect a printer.');
    } catch (_) {
      if (!context.mounted) return;
      await _printerError(context,
          title: 'Print failed',
          message: 'Check the printer connection and try again.');
    }
  }

  static Future<void> _printerError(BuildContext context,
      {required String title, required String message}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('OK')),
        ],
      ),
    );
  }

  /// Writes the PDF to a temp file and opens the system share/save sheet so the
  /// user can pick "Save to Files" / Downloads.
  static Future<void> savePdf(TransactionDetail detail,
      {required bool challan}) async {
    final bytes = await buildPdf(detail, challan: challan);
    final name = fileName(detail, challan: challan);
    final dir = await getTemporaryDirectory();
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes(bytes);
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(file.path)],
        text: 'Save ${detail.transaction.transactionNumber}',
      ),
    );
  }
}
