import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/employee.dart';
import '../providers/employee_providers.dart';

/// Add or edit an employee — name, daily pay, and a few optional details.
class AddEditEmployeeScreen extends ConsumerStatefulWidget {
  final Employee? employee;
  const AddEditEmployeeScreen({super.key, this.employee});

  bool get isEditing => employee != null;

  @override
  ConsumerState<AddEditEmployeeScreen> createState() =>
      _AddEditEmployeeScreenState();
}

class _AddEditEmployeeScreenState extends ConsumerState<AddEditEmployeeScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _pay;
  late final TextEditingController _role;
  late final TextEditingController _phone;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.employee;
    _name = TextEditingController(text: e?.name ?? '');
    _pay = TextEditingController(
        text: e == null ? '' : Formatters.plain(e.dailyPay));
    _role = TextEditingController(text: e?.role ?? '');
    _phone = TextEditingController(text: e?.phone ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _pay.dispose();
    _role.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final repo = ref.read(employeeRepositoryProvider);
    final base = widget.employee;
    final employee = Employee(
      id: base?.id,
      name: _name.text.trim(),
      dailyPay: double.tryParse(_pay.text.trim()) ?? 0,
      role: _role.text.trim().isEmpty ? null : _role.text.trim(),
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      joinDate: base?.joinDate ?? DateTime.now().toIso8601String(),
      notes: base?.notes,
    );

    if (widget.isEditing) {
      await repo.update(employee);
    } else {
      await repo.insert(employee);
    }

    ref.invalidate(employeeListProvider);
    if (base?.id != null) ref.invalidate(employeeDetailProvider(base!.id!));
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit Employee' : 'Add Employee'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Name *',
                prefixIcon: Icon(Icons.badge_outlined),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Name is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _pay,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Pay per day *',
                prefixText: '₹ ',
                prefixIcon: Icon(Icons.payments_outlined),
                helperText: 'Wage for one full present day',
              ),
              validator: (v) {
                final n = double.tryParse((v ?? '').trim());
                if (n == null || n <= 0) return 'Enter a valid daily pay';
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _role,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Role (optional)',
                hintText: 'e.g. Helper, Driver, Cashier',
                prefixIcon: Icon(Icons.work_outline),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone (optional)',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            const SizedBox(height: 28),
            SizedBox(
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.check),
                label: Text(widget.isEditing ? 'Save Changes' : 'Add Employee'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
