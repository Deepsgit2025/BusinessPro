import 'dart:typed_data';

import '../models/transaction.dart';
import '../models/transaction_item.dart';
import 'invoice_pdf_service.dart';

/// The document categories that have selectable print layouts.
enum DocumentType { sale, estimate, purchase }

/// One selectable layout in the Bill Formats settings UI.
class FormatOption {
  final String key;
  final String name;
  final String description;
  const FormatOption(
      {required this.key, required this.name, required this.description});
}

/// Single entry point for generating a document PDF. Screens should call
/// [generate] / [generateAllCopies] rather than [InvoicePdfService] directly, so
/// adding a new format later is one case here + one method in the service — no
/// screen changes.
///
/// The underlying [InvoicePdfService.build] already chooses the concrete layout
/// from the transaction type and the saved `print_invoice_format` /
/// `print_estimate_format` settings; the registry is the typed, discoverable
/// surface over it and the source of [getFormats] for the settings screen.
class InvoiceFormatRegistry {
  InvoiceFormatRegistry._();

  /// Builds a single-page document PDF for [transaction]. For a sale the single
  /// page carries the Original copy label; estimates/purchases pass none.
  static Future<Uint8List> generate({
    required DocumentType docType,
    required Transaction transaction,
    required List<TransactionItem> items,
    String? copyLabel,
  }) {
    return InvoicePdfService.build(
      transaction: transaction,
      items: items,
      copyLabel: docType == DocumentType.sale
          ? (copyLabel ?? InvoicePdfService.copyLabels.first)
          : null,
    );
  }

  /// Builds the 3-copy set for a sale invoice (print only). Only sales have
  /// copies; other types should use [generate].
  static Future<Uint8List> generateAllCopies({
    required Transaction transaction,
    required List<TransactionItem> items,
    List<String>? labels,
  }) {
    return InvoicePdfService.buildAllCopies(
      transaction: transaction,
      items: items,
      labels: labels,
    );
  }

  /// The format key currently active for [docType] given loaded [settings].
  static String activeFormat(DocumentType docType, {required String invoice, required String estimate}) {
    return switch (docType) {
      DocumentType.estimate => estimate,
      _ => invoice,
    };
  }

  /// The settings key that stores the active format for [docType].
  static String settingKey(DocumentType docType) => switch (docType) {
        DocumentType.sale => 'print_invoice_format',
        DocumentType.estimate => 'print_estimate_format',
        DocumentType.purchase => 'print_purchase_format',
      };

  /// All layouts offered for a document type — drives the Bill Formats UI.
  /// New formats are added here (and a matching branch in the PDF service).
  static List<FormatOption> getFormats(DocumentType docType) {
    return switch (docType) {
      DocumentType.sale => const [
          FormatOption(
            key: 'format1',
            name: 'Format 1',
            description:
                'GST tax invoice with transport details, HSN/SAC tax breakup, '
                'UPI QR, and 3 print copies.',
          ),
        ],
      DocumentType.estimate => const [
          FormatOption(
            key: 'format2',
            name: 'Format 2',
            description:
                'Quotation layout with a Unit column, Sub Total + Total only, '
                'and Terms & Conditions in the footer.',
          ),
        ],
      DocumentType.purchase => const [
          FormatOption(
            key: 'format1',
            name: 'Format 1',
            description: 'Standard purchase bill.',
          ),
        ],
    };
  }
}
