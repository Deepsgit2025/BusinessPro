import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/formatters.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../models/account.dart';
import '../providers/account_providers.dart';

/// Transfer money between two accounts. Records a paired payment_out / payment_in
/// so the balance triggers move the money in one atomic step.
class MoneyTransferScreen extends ConsumerStatefulWidget {
  const MoneyTransferScreen({super.key});

  @override
  ConsumerState<MoneyTransferScreen> createState() =>
      _MoneyTransferScreenState();
}

class _MoneyTransferScreenState extends ConsumerState<MoneyTransferScreen> {
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  int? _fromId;
  int? _toId;
  DateTime _date = DateTime.now();
  bool _saving = false;

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _transfer() async {
    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    if (_fromId == null || _toId == null) {
      _snack('Select both accounts');
      return;
    }
    if (_fromId == _toId) {
      _snack('Source and destination must differ');
      return;
    }
    if (amount <= 0) {
      _snack('Enter a valid amount');
      return;
    }
    setState(() => _saving = true);

    try {
      final cashModeId =
          await ref.read(txnMetaRepositoryProvider).defaultPaymentModeId();
      await ref.read(accountRepoProvider).transfer(
            fromAccountId: _fromId!,
            toAccountId: _toId!,
            amount: amount,
            date: _date.toIso8601String(),
            notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
            cashModeId: cashModeId,
          );
      ref.invalidate(accountListProvider);
      ref.invalidate(totalBalanceProvider);
      if (!mounted) return;
      Navigator.pop(context, true);
      _snack('Transfer complete');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Could not transfer: $e');
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final accountsAsync = ref.watch(accountListProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Transfer Money')),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (accounts) {
          if (accounts.length < 2) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'You need at least two accounts to transfer money.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _accountDropdown('From Account', _fromId, accounts,
                  (v) => setState(() => _fromId = v)),
              const SizedBox(height: 16),
              _accountDropdown('To Account', _toId, accounts,
                  (v) => setState(() => _toId = v)),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
                ],
                decoration: const InputDecoration(labelText: 'Amount ₹'),
              ),
              const SizedBox(height: 16),
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
                  decoration: const InputDecoration(labelText: 'Date'),
                  child: Text(Formatters.date(_date.toIso8601String())),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _notes,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _saving ? null : _transfer,
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Transfer'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _accountDropdown(String label, int? value, List<Account> accounts,
      ValueChanged<int?> onChanged) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      items: accounts
          .map((a) => DropdownMenuItem(
                value: a.id,
                child: Text(
                    '${a.name}  (${Formatters.currency(a.currentBalance)})'),
              ))
          .toList(),
      onChanged: onChanged,
    );
  }
}
