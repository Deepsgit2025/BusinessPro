import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/account.dart';
import '../providers/account_providers.dart';

/// Add or edit a cash / bank / wallet account. Pass [account] to edit.
class AddAccountScreen extends ConsumerStatefulWidget {
  final Account? account;
  const AddAccountScreen({super.key, this.account});

  bool get isEdit => account != null;

  @override
  ConsumerState<AddAccountScreen> createState() => _AddAccountScreenState();
}

class _AddAccountScreenState extends ConsumerState<AddAccountScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _bankName;
  late final TextEditingController _accountNo;
  late final TextEditingController _ifsc;
  late final TextEditingController _opening;

  late String _type;
  late bool _isDefault;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final a = widget.account;
    _name = TextEditingController(text: a?.name ?? '');
    _bankName = TextEditingController(text: a?.bankName ?? '');
    _accountNo = TextEditingController(text: a?.accountNumber ?? '');
    _ifsc = TextEditingController(text: a?.ifscCode ?? '');
    _opening = TextEditingController(
        text: (a?.openingBalance ?? 0) == 0 ? '' : _fmt(a!.openingBalance));
    _type = a?.accountType ?? 'bank';
    _isDefault = a?.isDefault ?? false;
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    _name.dispose();
    _bankName.dispose();
    _accountNo.dispose();
    _ifsc.dispose();
    _opening.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final account = Account(
      id: widget.account?.id,
      name: _name.text.trim(),
      accountType: _type,
      bankName: _bankName.text.trim().isEmpty ? null : _bankName.text.trim(),
      accountNumber:
          _accountNo.text.trim().isEmpty ? null : _accountNo.text.trim(),
      ifscCode: _ifsc.text.trim().isEmpty ? null : _ifsc.text.trim(),
      openingBalance: double.tryParse(_opening.text.trim()) ?? 0,
      isDefault: _isDefault,
    );

    final repo = ref.read(accountRepoProvider);
    try {
      if (widget.isEdit) {
        await repo.update(account);
      } else {
        await repo.insert(account);
      }
      ref.invalidate(accountListProvider);
      ref.invalidate(totalBalanceProvider);
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final isBank = _type == 'bank';
    // Only one cash account is allowed. Offer "Cash" as a type only when no
    // other active cash account exists (or when editing that cash account).
    final existing =
        ref.watch(accountListProvider).valueOrNull ?? const <Account>[];
    final hasOtherCash = existing
        .any((a) => a.accountType == 'cash' && a.id != widget.account?.id);
    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? 'Edit Account' : 'Add Account')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Account Name *'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 16),
            const Text('Type',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: [
                if (!hasOtherCash)
                  const ButtonSegment(value: 'cash', label: Text('Cash')),
                const ButtonSegment(value: 'bank', label: Text('Bank')),
                const ButtonSegment(value: 'wallet', label: Text('Wallet')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 16),
            if (isBank) ...[
              TextFormField(
                controller: _bankName,
                decoration: const InputDecoration(labelText: 'Bank Name'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _accountNo,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Account No.'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _ifsc,
                textCapitalization: TextCapitalization.characters,
                decoration: const InputDecoration(labelText: 'IFSC Code'),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _opening,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^-?\d*\.?\d*')),
              ],
              decoration: const InputDecoration(labelText: 'Opening Balance ₹'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _isDefault,
              onChanged: (v) => setState(() => _isDefault = v),
              title: const Text('Set as Default'),
            ),
            const SizedBox(height: 16),
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
