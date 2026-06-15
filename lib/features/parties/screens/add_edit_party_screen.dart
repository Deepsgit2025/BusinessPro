import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_lists.dart';
import '../models/party.dart';
import '../providers/party_providers.dart';

/// Add or edit a party. Pass [party] to edit; omit to add.
class AddEditPartyScreen extends ConsumerStatefulWidget {
  final Party? party;
  const AddEditPartyScreen({super.key, this.party});

  bool get isEdit => party != null;

  @override
  ConsumerState<AddEditPartyScreen> createState() => _AddEditPartyScreenState();
}

class _AddEditPartyScreenState extends ConsumerState<AddEditPartyScreen> {
  final _formKey = GlobalKey<FormState>();

  late String _partyType;
  late String _openingBalanceType;
  String? _state;
  bool _saving = false;

  late final TextEditingController _name;
  late final TextEditingController _phone;
  late final TextEditingController _altPhone;
  late final TextEditingController _email;
  late final TextEditingController _gstin;
  late final TextEditingController _pan;
  late final TextEditingController _creditLimit;
  late final TextEditingController _creditDays;
  late final TextEditingController _openingBalance;
  late final TextEditingController _address;
  late final TextEditingController _city;
  late final TextEditingController _pincode;
  late final TextEditingController _notes;

  @override
  void initState() {
    super.initState();
    final p = widget.party;
    _partyType = p?.partyType ?? 'customer';
    _openingBalanceType = p?.openingBalanceType ?? 'debit';
    _state = (p?.billingState != null && AppLists.indianStates.contains(p!.billingState))
        ? p.billingState
        : null;

    _name = TextEditingController(text: p?.name ?? '');
    _phone = TextEditingController(text: p?.phone ?? '');
    _altPhone = TextEditingController(text: p?.alternatePhone ?? '');
    _email = TextEditingController(text: p?.email ?? '');
    _gstin = TextEditingController(text: p?.gstin ?? '');
    _pan = TextEditingController(text: p?.panNumber ?? '');
    _creditLimit = TextEditingController(
        text: (p?.creditLimit ?? 0) == 0 ? '' : _trim(p!.creditLimit));
    _creditDays = TextEditingController(
        text: (p?.creditDays ?? 0) == 0 ? '' : p!.creditDays.toString());
    _openingBalance = TextEditingController(
        text: (p?.openingBalance ?? 0) == 0 ? '' : _trim(p!.openingBalance));
    _address = TextEditingController(text: p?.billingAddress ?? '');
    _city = TextEditingController(text: p?.billingCity ?? '');
    _pincode = TextEditingController(text: p?.billingPincode ?? '');
    _notes = TextEditingController(text: p?.notes ?? '');
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    for (final c in [
      _name, _phone, _altPhone, _email, _gstin, _pan, _creditLimit,
      _creditDays, _openingBalance, _address, _city, _pincode, _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double _parseNum(TextEditingController c) =>
      double.tryParse(c.text.trim()) ?? 0;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final repo = ref.read(partyRepositoryProvider);
    final party = Party(
      id: widget.party?.id,
      name: _name.text.trim(),
      partyType: _partyType,
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      alternatePhone: _altPhone.text.trim().isEmpty ? null : _altPhone.text.trim(),
      email: _email.text.trim().isEmpty ? null : _email.text.trim(),
      gstin: _gstin.text.trim().isEmpty ? null : _gstin.text.trim().toUpperCase(),
      panNumber: _pan.text.trim().isEmpty ? null : _pan.text.trim().toUpperCase(),
      creditLimit: _parseNum(_creditLimit),
      creditDays: int.tryParse(_creditDays.text.trim()) ?? 0,
      openingBalance: _parseNum(_openingBalance),
      openingBalanceType: _openingBalanceType,
      billingAddress: _address.text.trim().isEmpty ? null : _address.text.trim(),
      billingCity: _city.text.trim().isEmpty ? null : _city.text.trim(),
      billingState: _state,
      billingPincode: _pincode.text.trim().isEmpty ? null : _pincode.text.trim(),
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );

    try {
      if (widget.isEdit) {
        await repo.update(party);
      } else {
        await repo.insert(party);
      }
      ref.invalidate(partyListProvider);
      if (widget.party?.id != null) {
        ref.invalidate(partyDetailProvider(widget.party!.id!));
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Party ${widget.isEdit ? 'updated' : 'saved'}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save: $e')),
      );
    }
  }

  Future<void> _delete() async {
    final id = widget.party!.id!;
    final repo = ref.read(partyRepositoryProvider);
    final txnCount = await repo.transactionCount(id);
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${widget.party!.name}?'),
        content: Text(
          txnCount > 0
              ? 'This party has $txnCount transaction(s). Deleting will not '
                  'remove those transactions.\n\nThis cannot be undone.'
              : 'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.expense),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await repo.softDelete(id);
      ref.invalidate(partyListProvider);
      if (!mounted) return;
      // Pop back past the detail screen to the list.
      Navigator.pop(context, 'deleted');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEdit ? 'Edit Party' : 'Add Party'),
        actions: widget.isEdit
            ? [
                PopupMenuButton<String>(
                  onSelected: (v) {
                    if (v == 'delete') _delete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'delete', child: Text('Delete Party')),
                  ],
                ),
              ]
            : null,
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _label('Party Type'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'customer', label: Text('Customer')),
                ButtonSegment(value: 'supplier', label: Text('Supplier')),
                ButtonSegment(value: 'both', label: Text('Both')),
              ],
              selected: {_partyType},
              onSelectionChanged: (s) => setState(() => _partyType = s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 16),

            _field(_name, 'Name *', textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Name is required' : null),
            _field(_phone, 'Phone', keyboardType: TextInputType.phone,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly]),
            _field(_altPhone, 'Alternate Phone', keyboardType: TextInputType.phone),
            _field(_email, 'Email', keyboardType: TextInputType.emailAddress),
            _field(_gstin, 'GSTIN', maxLength: 15,
                textCapitalization: TextCapitalization.characters,
                validator: (v) {
              final t = v?.trim() ?? '';
              if (t.isEmpty) return null;
              if (t.length != 15 || !RegExp(r'^[0-9A-Za-z]{15}$').hasMatch(t)) {
                return 'GSTIN must be 15 alphanumeric characters';
              }
              return null;
            }),
            // PAN Number field hidden from the UI (Invoice Format 1). The
            // column and any existing value are preserved: _pan keeps the
            // loaded value and is still written back on save.

            const SizedBox(height: 8),
            _label('Credit & Opening Balance'),
            Row(
              children: [
                Expanded(child: _field(_creditLimit, 'Credit Limit',
                    keyboardType: TextInputType.number, dense: true)),
                const SizedBox(width: 12),
                Expanded(child: _field(_creditDays, 'Credit Days',
                    keyboardType: TextInputType.number, dense: true,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly])),
              ],
            ),
            _field(_openingBalance, 'Opening Balance',
                keyboardType: TextInputType.number),
            const SizedBox(height: 4),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'debit', label: Text('To Collect')),
                ButtonSegment(value: 'credit', label: Text('To Pay')),
              ],
              selected: {_openingBalanceType},
              onSelectionChanged: (s) =>
                  setState(() => _openingBalanceType = s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 16),

            _label('Billing Address'),
            _field(_address, 'Address', maxLines: 2),
            _field(_city, 'City'),
            DropdownButtonFormField<String>(
              initialValue: _state,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'State'),
              items: AppLists.indianStates
                  .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _state = v),
            ),
            const SizedBox(height: 12),
            _field(_pincode, 'Pincode', keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly]),

            const SizedBox(height: 8),
            _label('Notes'),
            _field(_notes, 'Notes', maxLines: 3),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 4),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
                letterSpacing: 0.5)),
      );

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    int maxLines = 1,
    int? maxLength,
    bool dense = false,
    TextCapitalization textCapitalization = TextCapitalization.none,
    List<TextInputFormatter>? inputFormatters,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: dense ? 0 : 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        maxLength: maxLength,
        textCapitalization: textCapitalization,
        inputFormatters: inputFormatters,
        validator: validator,
        decoration: InputDecoration(
          labelText: label,
          counterText: maxLength != null ? '' : null,
        ),
      ),
    );
  }
}
