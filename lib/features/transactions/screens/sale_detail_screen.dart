import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/formatters.dart';
import '../../parties/repositories/party_repository.dart';
import '../models/payment.dart';
import '../models/transaction.dart';
import '../models/transaction_item.dart';
import '../providers/transaction_providers.dart';
import '../services/invoice_pdf_service.dart';
import '../widgets/payment_bottom_sheet.dart';
import 'add_edit_transaction_screen.dart';
import 'add_payment_in_screen.dart';
import 'add_payment_out_screen.dart';

/// Read-only invoice / bill view with payment history and actions
/// (Record Payment, Edit, Cancel). Handles sale, purchase, and estimate detail.
class SaleDetailScreen extends ConsumerWidget {
  final int transactionId;
  const SaleDetailScreen({super.key, required this.transactionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(transactionDetailProvider(transactionId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Details'),
        actions: [
          detailAsync.maybeWhen(
            data: (d) => d == null
                ? const SizedBox.shrink()
                : _Menu(detail: d, transactionId: transactionId),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: detailAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) {
          if (d == null) return const Center(child: Text('Not found'));
          return _DetailBody(detail: d);
        },
      ),
      bottomNavigationBar: detailAsync.maybeWhen(
        data: (d) => d == null ? null : _ActionBar(detail: d),
        orElse: () => null,
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final TransactionDetail detail;
  const _DetailBody({required this.detail});

  @override
  Widget build(BuildContext context) {
    final t = detail.transaction;
    final isPurchase = t.transactionType == TxnTypes.purchase ||
        t.transactionType == TxnTypes.purchaseReturn ||
        t.transactionType == TxnTypes.purchaseOrder ||
        t.transactionType == TxnTypes.paymentOut;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(t.transactionNumber,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold)),
                Text(Formatters.date(t.transactionDate),
                    style: const TextStyle(color: AppColors.textSecondary)),
              ],
            ),
            if (t.isCancelled)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.expense.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('CANCELLED',
                    style: TextStyle(
                        color: AppColors.expense,
                        fontWeight: FontWeight.bold,
                        fontSize: 11)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (t.partyName != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(t.partyName!),
              subtitle: Text(isPurchase ? 'Supplier' : 'Customer'),
            ),
          ),
        const SizedBox(height: 12),
        _ItemTable(items: detail.items),
        const SizedBox(height: 12),
        _TotalsCard(t: t),
        const SizedBox(height: 12),
        if (detail.payments.isNotEmpty) _PaymentHistory(payments: detail.payments),
        if (t.balanceAmount > 0 && !t.isCancelled) ...[
          const SizedBox(height: 12),
          Card(
            color: AppColors.expense.withValues(alpha: 0.06),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Balance Due',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  Text(Formatters.currency(t.balanceAmount),
                      style: const TextStyle(
                          color: AppColors.expense,
                          fontWeight: FontWeight.bold,
                          fontSize: 18)),
                ],
              ),
            ),
          ),
        ],
        if (t.notes != null && t.notes!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Notes',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                  const SizedBox(height: 4),
                  Text(t.notes!),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 80),
      ],
    );
  }
}

class _ItemTable extends StatelessWidget {
  final List<TransactionItem> items;
  const _ItemTable({required this.items});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Column(
        children: [
          for (final it in items)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(it.itemName,
                            style:
                                const TextStyle(fontWeight: FontWeight.w500)),
                        Text(
                          '${Formatters.qty(it.quantity, it.unitName)} × '
                          '${Formatters.currency(it.unitPrice)}'
                          '${it.discountAmount > 0 ? '  −${Formatters.currency(it.discountAmount)}' : ''}'
                          '${it.taxAmount > 0 ? '  +${it.taxRate.toStringAsFixed(it.taxRate == it.taxRate.roundToDouble() ? 0 : 1)}% tax' : ''}',
                          style: const TextStyle(
                              fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  Text(Formatters.currency(it.totalAmount),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  final Transaction t;
  const _TotalsCard({required this.t});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Column(
          children: [
            _row('Subtotal', t.subtotal),
            if (t.discountAmount > 0) _row('Discount (-)', -t.discountAmount),
            _row('Taxable Amount', t.taxableAmount),
            if (t.cgstAmount > 0) _row('CGST (+)', t.cgstAmount),
            if (t.sgstAmount > 0) _row('SGST (+)', t.sgstAmount),
            if (t.igstAmount > 0) _row('IGST (+)', t.igstAmount),
            if (t.roundOff != 0) _row('Round Off', t.roundOff),
            const Divider(height: 16),
            _row('Total', t.totalAmount, bold: true),
            if (t.paidAmount > 0) _row('Paid', t.paidAmount, color: AppColors.income),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, double value,
      {bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  color: color ?? AppColors.textSecondary,
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
          Text(Formatters.currency(value),
              style: TextStyle(
                  fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                  color: color,
                  fontSize: bold ? 16 : 13)),
        ],
      ),
    );
  }
}

class _PaymentHistory extends StatelessWidget {
  final List<Payment> payments;
  const _PaymentHistory({required this.payments});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Payment History',
                style: TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            for (final p in payments)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(Formatters.date(p.paymentDate),
                            style: const TextStyle(fontSize: 13)),
                        Text(
                          [
                            if (p.modeName != null) p.modeName!,
                            if (p.accountName != null) p.accountName!,
                          ].join(' · '),
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                    Text(Formatters.currency(p.amount),
                        style: const TextStyle(
                            color: AppColors.income,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _ActionBar extends ConsumerWidget {
  final TransactionDetail detail;
  const _ActionBar({required this.detail});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = detail.transaction;

    // Estimate / Delivery Challan: offer "Convert to Invoice" unless already
    // converted.
    final isEstimate = t.transactionType == TxnTypes.estimate;
    final isChallan = t.transactionType == TxnTypes.deliveryChallan;
    if (isEstimate || isChallan) {
      if (t.status == 'converted') return const SizedBox.shrink();
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: ElevatedButton.icon(
            icon: const Icon(Icons.swap_horiz),
            label: const Text('Convert to Invoice'),
            onPressed: () => _convert(context, ref, t.id!, isChallan: isChallan),
          ),
        ),
      );
    }

    if (t.isCancelled) return const SizedBox.shrink();
    final canPay = t.balanceAmount > 0;
    if (!canPay) return const SizedBox.shrink();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ElevatedButton.icon(
          icon: const Icon(Icons.payments_outlined),
          label: const Text('Record Payment'),
          onPressed: () async {
            final payment = await showPaymentSheet(
              context,
              transactionId: t.id!,
              balanceDue: t.balanceAmount,
            );
            if (payment != null) {
              await ref
                  .read(transactionRepositoryProvider)
                  .recordPayment(payment);
              ref.invalidate(transactionDetailProvider(t.id!));
              ref.refreshTransactions();
            }
          },
        ),
      ),
    );
  }

  Future<void> _convert(BuildContext context, WidgetRef ref, int sourceId,
      {bool isChallan = false}) async {
    final repo = ref.read(transactionRepositoryProvider);
    final invoiceNumber = await _nextInvoiceNumber();
    final saleId = isChallan
        ? await repo.convertChallanToSale(sourceId, invoiceNumber)
        : await repo.convertEstimateToSale(sourceId, invoiceNumber);
    ref.invalidate(transactionDetailProvider(sourceId));
    ref.refreshTransactions();
    if (!context.mounted) return;
    // Replace the estimate detail with the new sale detail.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => SaleDetailScreen(transactionId: saleId)),
    );
  }

  Future<String> _nextInvoiceNumber() async {
    final biz = await DatabaseHelper.getBusiness();
    final prefix = biz?['invoice_prefix'] as String? ?? 'INV';
    final c = (biz?['invoice_counter'] as int?) ?? 1;
    return '$prefix-${c.toString().padLeft(4, '0')}';
  }
}

/// The overflow (⋮) menu shown on every document detail app bar — sale invoice,
/// payment-in receipt, credit note (sale return), estimate, and delivery
/// challan all open this screen.
///
/// The menu adapts to the document type: Duplicate, the PDF actions (open /
/// print / share / save), and Send SMS are offered for all of them; a sale
/// invoice additionally gets the delivery-challan PDF actions and a "Cancel
/// Invoice"; payment-in (a receipt) omits Cancel. Edit appears only while the
/// document is still editable (no payment recorded).
class _Menu extends ConsumerWidget {
  final TransactionDetail detail;
  final int transactionId;
  const _Menu({required this.detail, required this.transactionId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = detail.transaction;
    final editableAsync = ref.watch(transactionEditableProvider(transactionId));
    final canEdit = editableAsync.valueOrNull ?? false;

    final type = t.transactionType;
    final isSale = type == TxnTypes.sale;
    // Payment-In is a receipt: no Cancel action (matches the design), and it is
    // never editable via the standard sale/purchase form.
    final isPaymentIn =
        type == TxnTypes.paymentIn || type == TxnTypes.paymentOut;
    // PDF actions apply to every scoped document type shown on this screen.
    const pdfTypes = {
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
    final canPdf = pdfTypes.contains(type);
    // "Cancel" reads as "Cancel Invoice" only for an actual invoice.
    final cancelLabel = isSale ? 'Cancel Invoice' : 'Cancel';

    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      position: PopupMenuPosition.under,
      onSelected: (v) => _handle(context, ref, v),
      itemBuilder: (_) => [
        if (!t.isCancelled)
          _item('duplicate', Icons.copy_outlined, 'Duplicate'),
        if (canPdf) ...[
          _item('open_pdf', Icons.picture_as_pdf_outlined, 'Open PDF'),
          _item('print_pdf', Icons.print_outlined, 'Print PDF'),
          _item('share_pdf', Icons.share_outlined, 'Share PDF'),
          _item('save_pdf', Icons.download_outlined, 'Save PDF to Phone'),
        ],
        // The delivery-challan PDF only makes sense for a sale invoice.
        if (isSale) ...[
          _item('open_dc', Icons.local_shipping_outlined,
              'Open Delivery Challan'),
          _item('print_dc', Icons.print_outlined, 'Print Delivery Challan'),
          _item('share_dc', Icons.ios_share_outlined, 'Share Delivery Challan'),
        ],
        _item('sms', Icons.sms_outlined, 'Send SMS'),
        if (canEdit && !t.isCancelled) ...[
          const PopupMenuDivider(),
          _item('edit', Icons.edit_outlined, 'Edit'),
        ],
        // Payment-In has no Cancel; everything else can be cancelled.
        if (!t.isCancelled && !isPaymentIn)
          _item('cancel', Icons.cancel_outlined, cancelLabel,
              color: AppColors.expense),
        _item('delete', Icons.delete_outline, 'Delete',
            color: AppColors.expense),
      ],
    );
  }

  PopupMenuItem<String> _item(String value, IconData icon, String label,
      {Color? color}) {
    return PopupMenuItem<String>(
      value: value,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon, color: color),
        title: Text(label, style: TextStyle(color: color)),
      ),
    );
  }

  Future<void> _handle(
      BuildContext context, WidgetRef ref, String action) async {
    final t = detail.transaction;
    switch (action) {
      case 'duplicate':
        await _duplicate(context, ref);
      case 'open_pdf':
        await _openPdf(context, challan: false);
      case 'print_pdf':
        await _printPdf(challan: false);
      case 'share_pdf':
        await _sharePdf(challan: false);
      case 'save_pdf':
        await _savePdf(context, challan: false);
      case 'open_dc':
        await _openPdf(context, challan: true);
      case 'print_dc':
        await _printPdf(challan: true);
      case 'share_dc':
        await _sharePdf(challan: true);
      case 'sms':
        await _sendSms(context);
      case 'edit':
        final r = await Navigator.push<bool>(
          context,
          MaterialPageRoute(
            builder: (_) => AddEditTransactionScreen(
                mode: _formMode(t.transactionType), existingId: t.id),
          ),
        );
        if (r == true) {
          ref.invalidate(transactionDetailProvider(t.id!));
          ref.refreshTransactions();
        }
      case 'cancel':
        await _confirmAndRun(
          context,
          ref,
          title: t.transactionType == TxnTypes.sale ? 'Cancel Invoice' : 'Cancel',
          message:
              'Cancel ${t.transactionNumber}? Stock and payments will be '
              'reversed. The record is kept for your audit trail.',
          run: () => ref.read(transactionRepositoryProvider).cancel(t.id!),
          popAfter: false,
        );
      case 'delete':
        await _confirmAndRun(
          context,
          ref,
          title: 'Delete',
          message: 'Delete ${t.transactionNumber}? This removes it from your '
              'lists and balances.',
          run: () => ref.read(transactionRepositoryProvider).softDelete(t.id!),
          popAfter: true,
        );
    }
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  /// Maps a transaction type to the add/edit form mode used to create / edit it.
  static TxnFormMode _formMode(String type) => switch (type) {
        TxnTypes.purchase => TxnFormMode.purchase,
        TxnTypes.estimate => TxnFormMode.estimate,
        TxnTypes.deliveryChallan => TxnFormMode.deliveryChallan,
        TxnTypes.saleReturn => TxnFormMode.saleReturn,
        TxnTypes.saleOrder => TxnFormMode.saleOrder,
        TxnTypes.purchaseReturn => TxnFormMode.purchaseReturn,
        TxnTypes.purchaseOrder => TxnFormMode.purchaseOrder,
        _ => TxnFormMode.sale,
      };

  Future<void> _duplicate(BuildContext context, WidgetRef ref) async {
    final t = detail.transaction;
    // Payment-In/Out are created on their own dedicated screens, which have no
    // prefill; open a fresh form so the user can re-enter it.
    if (t.transactionType == TxnTypes.paymentIn) {
      final r = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const AddPaymentInScreen()),
      );
      if (r == true) ref.refreshTransactions();
      return;
    }
    if (t.transactionType == TxnTypes.paymentOut) {
      final r = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const AddPaymentOutScreen()),
      );
      if (r == true) ref.refreshTransactions();
      return;
    }
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AddEditTransactionScreen(
            mode: _formMode(t.transactionType), duplicateFromId: t.id),
      ),
    );
    if (r == true) ref.refreshTransactions();
  }

  Future<void> _confirmAndRun(
    BuildContext context,
    WidgetRef ref, {
    required String title,
    required String message,
    required Future<void> Function() run,
    required bool popAfter,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('No')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes')),
        ],
      ),
    );
    if (ok != true) return;
    final id = detail.transaction.id!;
    await run();
    ref.invalidate(transactionDetailProvider(id));
    ref.refreshTransactions();
    if (popAfter && context.mounted) Navigator.pop(context);
  }

  /// Opens the phone's SMS app addressed to the customer (if a number is on the
  /// party record) pre-filled with a short invoice summary.
  Future<void> _sendSms(BuildContext context) async {
    final t = detail.transaction;
    final phone = await _partyPhone();
    final biz = await DatabaseHelper.getBusiness();
    final bizName = ((biz?['name'] as String?)?.trim().isNotEmpty ?? false)
        ? (biz!['name'] as String).trim()
        : 'BusinessPro';
    // Word the message for the document type (a receipt vs an invoice/estimate).
    final noun = switch (t.transactionType) {
      TxnTypes.paymentIn => 'Payment receipt',
      TxnTypes.paymentOut => 'Payment voucher',
      TxnTypes.estimate => 'Estimate',
      TxnTypes.deliveryChallan => 'Delivery challan',
      TxnTypes.saleReturn => 'Credit note',
      TxnTypes.purchaseReturn => 'Debit note',
      TxnTypes.purchaseOrder => 'Purchase order',
      TxnTypes.purchase => 'Purchase bill',
      _ => 'Invoice',
    };
    final body = '$bizName: $noun ${t.transactionNumber} for '
        '${Formatters.currency(t.totalAmount)}'
        '${t.balanceAmount > 0 ? ' (Balance ${Formatters.currency(t.balanceAmount)})' : ''}.'
        ' Thank you.';
    final uri = Uri(
      scheme: 'sms',
      path: phone ?? '',
      queryParameters: {'body': body},
    );
    final launched =
        await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No SMS app available')),
      );
    }
  }

  Future<String?> _partyPhone() async {
    final pid = detail.transaction.partyId;
    if (pid == null) return null;
    final party = await PartyRepository().getById(pid);
    final phone = party?.phone?.trim();
    return (phone == null || phone.isEmpty) ? null : phone;
  }

  // ── PDF plumbing (invoice + delivery challan share the builder) ─────────────

  /// Builds the PDF bytes from the already-loaded detail. When [challan] is true
  /// it renders the delivery-challan variant (no prices, 'DELIVERY CHALLAN'
  /// title).
  Future<Uint8List> _buildPdf({required bool challan}) => InvoicePdfService.build(
        transaction: detail.transaction,
        items: detail.items,
        docTitleOverride: challan ? 'DELIVERY CHALLAN' : null,
        hidePrices: challan,
      );

  String _fileName({required bool challan}) {
    final base = detail.transaction.transactionNumber
        .replaceAll(RegExp(r'[^\w\-]'), '_');
    return challan ? '${base}_DC.pdf' : '$base.pdf';
  }

  Future<void> _openPdf(BuildContext context, {required bool challan}) async {
    final title = challan
        ? '${detail.transaction.transactionNumber} (Challan)'
        : detail.transaction.transactionNumber;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(title)),
          body: PdfPreview(
            build: (_) => _buildPdf(challan: challan),
            canChangePageFormat: false,
            canChangeOrientation: false,
            pdfFileName: _fileName(challan: challan),
          ),
        ),
      ),
    );
  }

  Future<void> _sharePdf({required bool challan}) async {
    final bytes = await _buildPdf(challan: challan);
    await Printing.sharePdf(bytes: bytes, filename: _fileName(challan: challan));
  }

  Future<void> _printPdf({required bool challan}) async {
    await Printing.layoutPdf(onLayout: (_) => _buildPdf(challan: challan));
  }

  /// Writes the PDF to a temp file and opens the system share/save sheet so the
  /// user can pick "Save to Files" / Downloads.
  Future<void> _savePdf(BuildContext context, {required bool challan}) async {
    final bytes = await _buildPdf(challan: challan);
    final name = _fileName(challan: challan);
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
