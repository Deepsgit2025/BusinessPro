import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../services/ocr/bill_parser.dart';

/// Review screen shown after a bill is scanned and parsed, before any data is
/// applied to the Purchase form. Shows what was found with confidence colouring,
/// lets the user correct every field, exposes the raw OCR text, and returns the
/// (possibly edited) [BillParseResult] when the user taps "Use This Data".
///
/// Pops with the edited result on apply, or `null` on "Scan Again" / dismiss.
class ScanResultScreen extends StatefulWidget {
  final BillParseResult result;

  const ScanResultScreen({super.key, required this.result});

  @override
  State<ScanResultScreen> createState() => _ScanResultScreenState();
}

class _ScanResultScreenState extends State<ScanResultScreen> {
  late final TextEditingController _supplierName;
  late final TextEditingController _gstin;
  late final TextEditingController _billNumber;
  late final TextEditingController _subtotal;
  late final TextEditingController _tax;
  late final TextEditingController _total;
  DateTime? _billDate;
  bool _showRaw = false;

  @override
  void initState() {
    super.initState();
    final r = widget.result;
    _supplierName = TextEditingController(text: r.supplierName ?? '');
    _gstin = TextEditingController(text: r.supplierGstin ?? '');
    _billNumber = TextEditingController(text: r.billNumber ?? '');
    _subtotal =
        TextEditingController(text: r.subtotal == null ? '' : Formatters.plain(r.subtotal!));
    _tax = TextEditingController(
        text: r.taxAmount == null ? '' : Formatters.plain(r.taxAmount!));
    _total = TextEditingController(
        text: r.totalAmount == null ? '' : Formatters.plain(r.totalAmount!));
    _billDate = r.billDate;
  }

  @override
  void dispose() {
    _supplierName.dispose();
    _gstin.dispose();
    _billNumber.dispose();
    _subtotal.dispose();
    _tax.dispose();
    _total.dispose();
    super.dispose();
  }

  /// Builds the edited result from the current field values. Empty text fields
  /// become null so the apply step skips them.
  BillParseResult _edited() {
    String? text(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    double? amount(TextEditingController c) =>
        double.tryParse(c.text.trim().replaceAll(',', ''));

    return BillParseResult(
      supplierName: text(_supplierName),
      supplierGstin: text(_gstin),
      billNumber: text(_billNumber),
      billDate: _billDate,
      subtotal: amount(_subtotal),
      taxAmount: amount(_tax),
      totalAmount: amount(_total),
      lineItems: widget.result.lineItems,
      rawText: widget.result.rawText,
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    return Scaffold(
      backgroundColor: AppColors.surface(context),
      appBar: AppBar(
        backgroundColor: AppColors.surface(context),
        foregroundColor: AppColors.textPrimaryOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: AppColors.dividerOf(context))),
        title: const Text('Scan Results',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const Text('Review and correct before applying.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          const SizedBox(height: 16),

          _sectionHeader('Supplier Details'),
          _field('Supplier Name', _supplierName, found: r.supplierName != null),
          _field('GSTIN', _gstin,
              found: r.supplierGstin != null,
              textCapitalization: TextCapitalization.characters),
          _field('Bill Number', _billNumber, found: r.billNumber != null),
          _dateField(),
          const SizedBox(height: 20),

          _sectionHeader('Amounts'),
          _field('Subtotal', _subtotal,
              found: r.subtotal != null, numeric: true, prefix: '₹ '),
          _field('Tax Amount', _tax,
              found: r.taxAmount != null, numeric: true, prefix: '₹ '),
          _field('Total', _total,
              found: r.totalAmount != null, numeric: true, prefix: '₹ '),
          const SizedBox(height: 20),

          _sectionHeader('Items Found (${r.lineItems.length})'),
          if (r.lineItems.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'No line items detected — add them manually on the next screen.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
              ),
            )
          else
            ...r.lineItems.map(_lineItemTile),
          const SizedBox(height: 20),

          _rawTextToggle(r.rawText),
          const SizedBox(height: 24),

          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    side: const BorderSide(color: AppColors.border),
                  ),
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Scan Again'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: AppColors.partial,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: () => Navigator.pop(context, _edited()),
                  child: const Text('Use This Data',
                      style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(label.toUpperCase(),
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
                color: AppColors.textSecondary)),
      );

  /// Editable field with a leading confidence dot: green when parsed, grey when
  /// the parser found nothing (the user can still type it in).
  Widget _field(
    String label,
    TextEditingController controller, {
    required bool found,
    bool numeric = false,
    String? prefix,
    TextCapitalization textCapitalization = TextCapitalization.none,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(found ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: found ? AppColors.primary : AppColors.textHint),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              textCapitalization: textCapitalization,
              keyboardType: numeric
                  ? const TextInputType.numberWithOptions(decimal: true)
                  : TextInputType.text,
              inputFormatters: numeric
                  ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
                  : null,
              decoration: InputDecoration(
                labelText: label,
                prefixText: prefix,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateField() {
    final found = _billDate != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(found ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 16,
              color: found ? AppColors.primary : AppColors.textHint),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _billDate ?? DateTime.now(),
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _billDate = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Bill Date',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      _billDate == null
                          ? 'Not detected'
                          : Formatters.date(_billDate!.toIso8601String()),
                      style: TextStyle(
                          color: _billDate == null
                              ? AppColors.textHint
                              : AppColors.textPrimaryOf(context)),
                    ),
                    const Icon(Icons.calendar_today,
                        size: 18, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _lineItemTile(ParsedLineItem item) {
    final parts = <String>[
      if (item.quantity != null) Formatters.qty(item.quantity!, item.unit),
      if (item.unitPrice != null) '@ ${Formatters.currency(item.unitPrice!)}',
      if (item.totalPrice != null) '= ${Formatters.currency(item.totalPrice!)}',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.check_circle, size: 16, color: AppColors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.itemName,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                if (parts.isNotEmpty)
                  Text(parts.join('   '),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _rawTextToggle(String rawText) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _showRaw = !_showRaw),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(_showRaw ? Icons.expand_less : Icons.expand_more,
                    size: 20, color: AppColors.partial),
                const SizedBox(width: 4),
                Text(_showRaw ? 'Hide raw text' : 'Show raw text',
                    style: const TextStyle(
                        color: AppColors.partial, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
        if (_showRaw)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.background(context),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              rawText.isEmpty ? '(no text extracted)' : rawText,
              style: const TextStyle(
                  fontSize: 12, height: 1.4, color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }
}
