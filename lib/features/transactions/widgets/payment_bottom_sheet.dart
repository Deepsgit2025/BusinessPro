import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../cash_bank/models/account.dart';
import '../models/payment.dart';
import '../models/payment_mode.dart';
import '../providers/transaction_providers.dart';

/// Bottom sheet to record a payment against a transaction. Pre-fills the
/// outstanding [balanceDue] and offers a "Full" shortcut. Returns the built
/// [Payment] (transactionId already set) on save, or null if dismissed.
Future<Payment?> showPaymentSheet(
  BuildContext context, {
  required int transactionId,
  required double balanceDue,
}) {
  return showModalBottomSheet<Payment>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PaymentSheet(
      transactionId: transactionId,
      balanceDue: balanceDue,
    ),
  );
}

class _PaymentSheet extends ConsumerStatefulWidget {
  final int transactionId;
  final double balanceDue;
  const _PaymentSheet({required this.transactionId, required this.balanceDue});

  @override
  ConsumerState<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<_PaymentSheet> {
  late final TextEditingController _amount;
  final _ref = TextEditingController();
  final _notes = TextEditingController();
  DateTime _date = DateTime.now();
  int? _modeId;
  int? _accountId;

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: _fmt(widget.balanceDue));
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _save() {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a payment amount')),
      );
      return;
    }
    Navigator.pop(
      context,
      Payment(
        transactionId: widget.transactionId,
        accountId: _accountId,
        paymentModeId: _modeId,
        amount: amount,
        paymentDate: _date.toIso8601String(),
        referenceNumber: _ref.text.trim().isEmpty ? null : _ref.text.trim(),
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final modes = ref.watch(paymentModesProvider);
    final accounts = ref.watch(accountsProvider);

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Record Payment',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Balance due: ${Formatters.currency(widget.balanceDue)}',
              style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _amount,
                  autofocus: true,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                  ],
                  decoration: const InputDecoration(
                      labelText: 'Amount ₹', isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () =>
                    setState(() => _amount.text = _fmt(widget.balanceDue)),
                child: const Text('Full'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          modes.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('$e'),
            data: (list) => DropdownButtonFormField<int>(
              initialValue: _modeId,
              decoration:
                  const InputDecoration(labelText: 'Payment Mode', isDense: true),
              items: list
                  .map((PaymentMode m) =>
                      DropdownMenuItem(value: m.id, child: Text(m.name)))
                  .toList(),
              onChanged: (v) => setState(() => _modeId = v),
            ),
          ),
          const SizedBox(height: 12),
          accounts.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('$e'),
            data: (list) {
              _accountId ??= list.where((a) => a.isDefault).firstOrNull?.id ??
                  list.firstOrNull?.id;
              return DropdownButtonFormField<int>(
                initialValue: _accountId,
                decoration: const InputDecoration(
                    labelText: 'Deposit To', isDense: true),
                items: list
                    .map((Account a) =>
                        DropdownMenuItem(value: a.id, child: Text(a.name)))
                    .toList(),
                onChanged: (v) => setState(() => _accountId = v),
              );
            },
          ),
          const SizedBox(height: 12),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) setState(() => _date = picked);
            },
            child: InputDecorator(
              decoration:
                  const InputDecoration(labelText: 'Date', isDense: true),
              child: Text(Formatters.date(_date.toIso8601String())),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ref,
            decoration: const InputDecoration(
                labelText: 'Reference No.', isDense: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _notes,
            decoration:
                const InputDecoration(labelText: 'Notes', isDense: true),
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('Save Payment'),
            ),
          ),
        ],
      ),
    );
  }
}
