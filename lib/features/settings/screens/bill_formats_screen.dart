import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/database/database_helper.dart';
import '../../transactions/models/transaction.dart';
import '../../transactions/models/transaction_item.dart';
import '../../transactions/services/invoice_format_registry.dart';

/// Bill Formats settings — shows the active print layout for sale invoices
/// (Format 1) and estimates (Format 2), with a Preview that renders a sample
/// PDF and a Set Active control that persists the choice.
///
/// The app currently ships one layout per document type, so "Set Active" writes
/// the canonical key (`print_invoice_format` / `print_estimate_format`); the
/// screen is built to extend cleanly when more formats are added.
class BillFormatsScreen extends StatefulWidget {
  const BillFormatsScreen({super.key});

  @override
  State<BillFormatsScreen> createState() => _BillFormatsScreenState();
}

class _BillFormatsScreenState extends State<BillFormatsScreen> {
  String _invoiceFormat = 'format1';
  String _estimateFormat = 'format2';
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final inv = await DatabaseHelper.getSettingStr('print_invoice_format',
        defaultVal: 'format1');
    final est = await DatabaseHelper.getSettingStr('print_estimate_format',
        defaultVal: 'format2');
    if (!mounted) return;
    setState(() {
      _invoiceFormat = inv.isEmpty ? 'format1' : inv;
      _estimateFormat = est.isEmpty ? 'format2' : est;
      _loading = false;
    });
  }

  Future<void> _setActive(String key, String value) async {
    await DatabaseHelper.setSetting(key, value);
    if (!mounted) return;
    setState(() {
      if (key == 'print_invoice_format') _invoiceFormat = value;
      if (key == 'print_estimate_format') _estimateFormat = value;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Format set as active')));
  }

  // ── Sample data for the preview ───────────────────────────────────────────

  static final _sampleItems = const [
    TransactionItem(
      itemName: 'Single Jack Assembly',
      itemHsn: '84295900',
      unitName: 'Pcs',
      quantity: 1,
      unitPrice: 35238.10,
      taxRate: 5,
      taxableAmount: 35238.10,
      cgstAmount: 880.95,
      sgstAmount: 880.95,
      taxAmount: 1761.90,
      totalAmount: 37000,
    ),
    TransactionItem(
      itemName: 'Spring Loader',
      itemHsn: '84329090',
      unitName: 'Pcs',
      quantity: 1,
      unitPrice: 20952.38,
      taxRate: 5,
      taxableAmount: 20952.38,
      cgstAmount: 523.81,
      sgstAmount: 523.81,
      taxAmount: 1047.62,
      totalAmount: 22000,
    ),
  ];

  Transaction _sampleTxn({required bool estimate}) => Transaction(
        id: -1,
        transactionType: estimate ? TxnTypes.estimate : TxnTypes.sale,
        transactionNumber: estimate ? 'EST-0001' : 'INV-0001',
        transactionDate: DateTime.now().toIso8601String(),
        subtotal: 56190.48,
        taxableAmount: 56190.48,
        cgstAmount: 1404.76,
        sgstAmount: 1404.76,
        taxAmount: 2809.52,
        totalAmount: 59000,
        paidAmount: estimate ? 0 : 59000,
        balanceAmount: 0,
        paymentStatus: estimate ? 'unpaid' : 'paid',
        placeOfSupply: '10-Bihar',
        transportName: estimate ? null : 'Blue Dart',
        vehicleNumber: estimate ? null : 'BR01AB1234',
        termsConditions: 'Thank you for your business!',
        partyName: 'Sample Customer',
      );

  Future<void> _preview(BuildContext context, {required bool estimate}) async {
    final txn = _sampleTxn(estimate: estimate);
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(
              title: Text(estimate ? 'Estimate Preview' : 'Invoice Preview')),
          body: PdfPreview(
            // Sample PDF through the single registry entry point.
            build: (_) => InvoiceFormatRegistry.generate(
              docType:
                  estimate ? DocumentType.estimate : DocumentType.sale,
              transaction: txn,
              items: _sampleItems,
            ),
            canChangePageFormat: false,
            canChangeOrientation: false,
            pdfFileName: estimate ? 'estimate_sample.pdf' : 'invoice_sample.pdf',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bill Formats')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _FormatCard(
                  title: 'Sale Invoice',
                  formatName: 'Format 1',
                  description:
                      'GST tax invoice with transport details, HSN/SAC tax '
                      'breakup, UPI QR, and 3 print copies.',
                  active: _invoiceFormat == 'format1',
                  onPreview: () => _preview(context, estimate: false),
                  onSetActive: () =>
                      _setActive('print_invoice_format', 'format1'),
                ),
                const SizedBox(height: 16),
                _FormatCard(
                  title: 'Estimate / Quotation',
                  formatName: 'Format 2',
                  description:
                      'Quotation layout with a Unit column, Sub Total + Total '
                      'only, and Terms & Conditions in the footer.',
                  active: _estimateFormat == 'format2',
                  onPreview: () => _preview(context, estimate: true),
                  onSetActive: () =>
                      _setActive('print_estimate_format', 'format2'),
                ),
              ],
            ),
    );
  }
}

class _FormatCard extends StatelessWidget {
  final String title;
  final String formatName;
  final String description;
  final bool active;
  final VoidCallback onPreview;
  final VoidCallback onSetActive;
  const _FormatCard({
    required this.title,
    required this.formatName,
    required this.description,
    required this.active,
    required this.onPreview,
    required this.onSetActive,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: active ? AppColors.primary : AppColors.dividerOf(context),
          width: active ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              if (active)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text('ACTIVE',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary)),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(formatName,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary)),
          const SizedBox(height: 8),
          Text(description,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary, height: 1.4)),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPreview,
                  icon: const Icon(Icons.visibility_outlined, size: 18),
                  label: const Text('Preview'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: active ? null : onSetActive,
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.primary),
                  child: Text(active ? 'Active' : 'Set Active'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
