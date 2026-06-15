import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/database/database_helper.dart';
import '../../../services/whatsapp/whatsapp_share_bottom_sheet.dart';
import '../../parties/models/party.dart';
import '../../parties/repositories/party_repository.dart';
import '../models/transaction.dart';
import '../models/transaction_item.dart';
import '../providers/transaction_providers.dart';
import '../services/invoice_format_registry.dart';
import '../services/transaction_share_service.dart';
import '../widgets/print_copies_sheet.dart';

/// Full-screen preview shown after a sale invoice is saved. Renders the saved
/// invoice (single Original copy) and offers WhatsApp / Share PDF / Print.
///
/// Reached via `Navigator.pushReplacement` from the add/edit screen, so the
/// add/edit form is gone — Back from here returns to the sale list.
class BillPreviewScreen extends ConsumerStatefulWidget {
  final int transactionId;
  const BillPreviewScreen({super.key, required this.transactionId});

  @override
  ConsumerState<BillPreviewScreen> createState() => _BillPreviewScreenState();
}

class _BillPreviewScreenState extends ConsumerState<BillPreviewScreen> {
  Transaction? _txn;
  List<TransactionItem> _items = const [];
  Map<String, dynamic>? _business;
  Party? _party;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(transactionRepositoryProvider);
    final txn = await repo.getById(widget.transactionId);
    final items = await repo.getItems(widget.transactionId);
    final business = await DatabaseHelper.getBusiness();
    final party = txn?.partyId == null
        ? null
        : await PartyRepository().getById(txn!.partyId!);
    if (!mounted) return;
    setState(() {
      _txn = txn;
      _items = items;
      _business = business;
      _party = party;
      _loading = false;
    });
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _shareWhatsApp() async {
    final txn = _txn;
    if (txn == null) return;
    await WhatsAppShareBottomSheet.show(
      context,
      transaction: txn,
      items: _items,
      business: _business,
      party: _party,
    );
  }

  Future<void> _sharePdf() async {
    final txn = _txn;
    if (txn == null) return;
    try {
      await TransactionShareService.share(
        context: context,
        transaction: txn,
        items: _items,
      );
    } catch (e) {
      if (mounted) _snack('Could not share: $e');
    }
  }

  bool get _isEstimate => _txn?.transactionType == TxnTypes.estimate;

  Future<void> _print() async {
    final txn = _txn;
    if (txn == null) return;
    try {
      // Estimates are a single page — print directly, no copy selection.
      if (_isEstimate) {
        await Printing.layoutPdf(
          onLayout: (_) => InvoiceFormatRegistry.generate(
            docType: DocumentType.estimate,
            transaction: txn,
            items: _items,
          ),
        );
        return;
      }
      // Sale invoices offer the 3-copy selection.
      final labels = await PrintCopiesSheet.show(context);
      if (labels == null || !mounted) return; // dismissed
      if (labels.isEmpty) {
        _snack('Select at least one copy to print');
        return;
      }
      await Printing.layoutPdf(
        onLayout: (_) => InvoiceFormatRegistry.generateAllCopies(
          transaction: txn,
          items: _items,
          labels: labels,
        ),
      );
    } catch (e) {
      if (mounted) _snack('Could not print: $e');
    }
  }

  /// Single-page document for the on-screen preview (Original copy for sales).
  Future<Uint8List> _previewBytes() => InvoiceFormatRegistry.generate(
        docType: _isEstimate ? DocumentType.estimate : DocumentType.sale,
        transaction: _txn!,
        items: _items,
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_txn == null
            ? 'Preview'
            : '${_isEstimate ? 'Estimate' : 'Invoice'} · ${_txn!.transactionNumber}'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _txn == null
              ? const Center(child: Text('Invoice not found'))
              : PdfPreview(
                  build: (_) => _previewBytes(),
                  canChangePageFormat: false,
                  canChangeOrientation: false,
                  allowPrinting: false,
                  allowSharing: false,
                  pdfFileName:
                      '${_txn!.transactionNumber.replaceAll(RegExp(r'[^\w\-]'), '_')}.pdf',
                ),
      bottomNavigationBar: _loading || _txn == null
          ? null
          : SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.surface(context),
                  border:
                      Border(top: BorderSide(color: AppColors.dividerOf(context))),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.chat_outlined,
                        label: 'WhatsApp',
                        color: const Color(0xFF25D366),
                        onTap: _shareWhatsApp,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.share_outlined,
                        label: 'Share PDF',
                        color: AppColors.partial,
                        onTap: _sharePdf,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.print_outlined,
                        label: 'Print',
                        color: AppColors.primary,
                        onTap: _print,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.12),
        foregroundColor: color,
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      onPressed: onTap,
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}
