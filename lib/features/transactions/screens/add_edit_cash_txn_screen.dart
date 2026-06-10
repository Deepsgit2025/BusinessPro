import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/expense_category.dart';
import '../models/payment.dart';
import '../models/transaction.dart';
import '../providers/transaction_providers.dart';

/// Shared add screen for expense / other_income — no party, no line items.
/// [isIncome] flips the labels, category set, and transaction type. Payment is
/// always immediate (these are never on credit), so the account balance moves
/// on save via the payment triggers.
class AddEditCashTxnScreen extends ConsumerStatefulWidget {
  final bool isIncome;
  const AddEditCashTxnScreen({super.key, required this.isIncome});

  @override
  ConsumerState<AddEditCashTxnScreen> createState() =>
      _AddEditCashTxnScreenState();
}

class _AddEditCashTxnScreenState extends ConsumerState<AddEditCashTxnScreen> {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _notes = TextEditingController();
  final _reference = TextEditingController();

  int? _categoryId;
  int? _paymentModeId;
  int? _accountId;
  DateTime _date = DateTime.now();
  bool _saving = false;

  String get _categoryFor => widget.isIncome ? 'income' : 'expense';
  String get _title => widget.isIncome ? 'Add Income' : 'Add Expense';

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _newCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Category name'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final id = await ref
          .read(txnMetaRepositoryProvider)
          .addCategory(name, _categoryFor);
      ref.invalidate(categoriesProvider(_categoryFor));
      setState(() => _categoryId = id);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_categoryId == null) {
      _snack('Select a category');
      return;
    }
    setState(() => _saving = true);

    final amount = double.tryParse(_amount.text.trim()) ?? 0;
    final repo = ref.read(transactionRepositoryProvider);
    final number =
        '${widget.isIncome ? 'INC' : 'EXP'}-${DateTime.now().millisecondsSinceEpoch}';

    final txn = Transaction(
      categoryId: _categoryId,
      accountId: _accountId,
      transactionType:
          widget.isIncome ? TxnTypes.otherIncome : TxnTypes.expense,
      transactionNumber: number,
      referenceNumber:
          _reference.text.trim().isEmpty ? null : _reference.text.trim(),
      transactionDate: _date.toIso8601String(),
      totalAmount: amount,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );

    final payment = Payment(
      accountId: _accountId,
      paymentModeId: _paymentModeId,
      amount: amount,
      paymentDate: _date.toIso8601String(),
    );

    try {
      await repo.createCashTransaction(txn, payment: payment);
      ref.refreshTransactions();
      if (!mounted) return;
      Navigator.pop(context, true);
      _snack('${widget.isIncome ? 'Income' : 'Expense'} saved');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack('Could not save: $e');
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider(_categoryFor));
    final modes = ref.watch(paymentModesProvider);
    final accounts = ref.watch(accountsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            categories.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('$e'),
              data: (list) => Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _categoryId,
                      isExpanded: true,
                      decoration:
                          const InputDecoration(labelText: 'Category'),
                      items: list
                          .map((ExpenseCategory c) => DropdownMenuItem(
                              value: c.id, child: Text(c.name)))
                          .toList(),
                      onChanged: (v) => setState(() => _categoryId = v),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline,
                        color: AppColors.primary),
                    onPressed: _newCategory,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _amount,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
              ],
              decoration: const InputDecoration(labelText: 'Amount ₹'),
              validator: (v) {
                final n = double.tryParse(v?.trim() ?? '');
                if (n == null || n <= 0) return 'Enter a valid amount';
                return null;
              },
            ),
            const SizedBox(height: 12),
            modes.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
              data: (list) {
                _paymentModeId ??=
                    list.where((m) => m.type == 'cash').firstOrNull?.id;
                return DropdownButtonFormField<int>(
                  initialValue: _paymentModeId,
                  decoration:
                      const InputDecoration(labelText: 'Payment Mode'),
                  items: list
                      .map((m) =>
                          DropdownMenuItem(value: m.id, child: Text(m.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _paymentModeId = v),
                );
              },
            ),
            const SizedBox(height: 12),
            accounts.when(
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
              data: (list) {
                _accountId ??= list.where((a) => a.isDefault).firstOrNull?.id ??
                    list.firstOrNull?.id;
                return DropdownButtonFormField<int>(
                  initialValue: _accountId,
                  decoration: const InputDecoration(labelText: 'Account'),
                  items: list
                      .map((a) =>
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
                decoration: const InputDecoration(labelText: 'Date'),
                child: Text(Formatters.date(_date.toIso8601String())),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _reference,
              decoration: const InputDecoration(labelText: 'Reference No.'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
