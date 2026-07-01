import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/formatters.dart';
import '../models/employee.dart';
import '../models/salary_payment.dart';
import '../providers/employee_providers.dart';
import '../services/salary_slip_pdf_service.dart';
import 'salary_slip_preview_screen.dart';

/// Calculates and records one month's salary for an employee.
///
/// The gross is computed fresh from the month's attendance roll-up
/// (full + half days × daily pay, plus overtime hours × overtime rate) and is
/// never stored until the user taps Save Payment. The payout splits into cash
/// and an amount credited against the outstanding advance.
class SalaryPaymentScreen extends ConsumerStatefulWidget {
  final int employeeId;
  final String month; // 'yyyy-MM'
  const SalaryPaymentScreen({
    super.key,
    required this.employeeId,
    required this.month,
  });

  @override
  ConsumerState<SalaryPaymentScreen> createState() =>
      _SalaryPaymentScreenState();
}

class _SalaryPaymentScreenState extends ConsumerState<SalaryPaymentScreen> {
  final _cash = TextEditingController();
  final _advanceCredit = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _cash.dispose();
    _advanceCredit.dispose();
    _notes.dispose();
    super.dispose();
  }

  String get _monthLabel {
    final parts = widget.month.split('-');
    if (parts.length != 2) return widget.month;
    final y = int.tryParse(parts[0]) ?? 2000;
    final m = int.tryParse(parts[1]) ?? 1;
    return DateFormat('MMMM yyyy').format(DateTime(y, m));
  }

  double _gross(Employee e) =>
      e.presentDays * e.dailyPay +
      e.halfDays * e.dailyPay / 2 +
      e.overtimeHours * e.overtimeRate;

  /// Builds the SalaryPayment snapshot from the current form + employee figures.
  SalaryPayment _payment(Employee e) {
    final gross = _gross(e);
    final cash = double.tryParse(_cash.text.trim()) ?? 0;
    final credit = double.tryParse(_advanceCredit.text.trim()) ?? 0;
    return SalaryPayment(
      employeeId: e.id!,
      paymentMonth: widget.month,
      salaryEarned: gross,
      cashPaid: cash,
      advanceCredited: credit,
      remaining: gross - cash - credit,
      fullDays: e.presentDays,
      halfDays: e.halfDays,
      absentDays: e.absentDays,
      overtimeHours: e.overtimeHours,
      overtimeAmount: e.overtimeHours * e.overtimeRate,
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      paymentDate: DateTime.now().toIso8601String().split('T').first,
    );
  }

  String? _validate(Employee e) {
    final gross = _gross(e);
    final cash = double.tryParse(_cash.text.trim()) ?? 0;
    final credit = double.tryParse(_advanceCredit.text.trim()) ?? 0;
    if (cash < 0 || credit < 0) return 'Amounts cannot be negative';
    if (cash + credit > gross + 0.001) {
      return 'Cash + advance credit cannot exceed the gross salary';
    }
    if (credit > e.advanceOutstanding + 0.001) {
      return 'Advance credit cannot exceed the outstanding advance';
    }
    return null;
  }

  Future<void> _save(Employee e) async {
    final err = _validate(e);
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    setState(() => _saving = true);
    await ref.read(employeeRepositoryProvider).recordSalaryPayment(_payment(e));
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  /// Builds the salary slip PDF and opens the preview screen, from which the user
  /// can view it and then WhatsApp / share / print. The PDF generation already
  /// works; the preview is the step that makes the slip actually visible.
  Future<void> _sendSlip(Employee e) async {
    final err = _validate(e);
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final payment = _payment(e);
      final pdf = await SalarySlipPdfService.build(
        employee: e,
        payment: payment,
        openingAdvance: e.advanceOutstanding,
      );
      final biz = await DatabaseHelper.getBusiness();
      final bizName = (biz?['name'] as String?)?.trim();
      if (!mounted) return;
      navigator.push(
        MaterialPageRoute(
          builder: (_) => SalarySlipPreviewScreen(
            pdfBytes: pdf,
            employee: e,
            payment: payment,
            monthLabel: _monthLabel,
            message: 'Dear ${e.name},\n'
                'Your salary slip for $_monthLabel.\n'
                '- ${bizName?.isNotEmpty == true ? bizName : 'BusinessPro'}',
          ),
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not open slip: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final empAsync = ref.watch(employeeDetailProvider(widget.employeeId));
    return Scaffold(
      appBar: AppBar(title: Text('Salary · $_monthLabel')),
      body: empAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (e) {
          if (e == null) return const Center(child: Text('Employee not found'));
          return _form(e);
        },
      ),
    );
  }

  Widget _form(Employee e) {
    final gross = _gross(e);
    final cash = double.tryParse(_cash.text.trim()) ?? 0;
    final credit = double.tryParse(_advanceCredit.text.trim()) ?? 0;
    final remaining = gross - cash - credit;
    final newOutstanding = e.advanceOutstanding - credit;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('${e.name} · $_monthLabel',
            style:
                const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        _card('Attendance Summary', [
          _kv('Full days', '${e.presentDays}',
              Formatters.currency(e.presentDays * e.dailyPay)),
          _kv('Half days', '${e.halfDays}',
              Formatters.currency(e.halfDays * e.dailyPay / 2)),
          _kv('Absent days', '${e.absentDays}', Formatters.currency(0)),
          // Overtime is a signed net: positive adds, a negative net (more
          // early-leave than overtime) deducts. Show either, hide only at zero.
          if (e.overtimeHours != 0)
            _kv(e.overtimeHours < 0 ? 'Overtime (early leave)' : 'Overtime',
                '${Formatters.plain(e.overtimeHours)} hrs',
                Formatters.currency(e.overtimeHours * e.overtimeRate)),
          const Divider(),
          _kv('Gross Salary', '', Formatters.currency(gross), bold: true),
        ]),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.expense.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Advance outstanding',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              Text(Formatters.currency(e.advanceOutstanding),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, color: AppColors.expense)),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card('Payment Split', [
          TextField(
            controller: _cash,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Cash to employee',
              prefixText: '₹ ',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _advanceCredit,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            // Entering an advance credit auto-fills "Cash to employee" with the
            // remainder (gross − credit) so the payout is fully allocated by
            // default. The user can still edit cash afterwards.
            onChanged: (v) {
              final credit = double.tryParse(v.trim()) ?? 0;
              final cash = (gross - credit).clamp(0.0, gross);
              _cash.text = Formatters.plain(cash);
              setState(() {});
            },
            decoration: const InputDecoration(
              labelText: 'Credit to advance',
              prefixText: '₹ ',
              border: OutlineInputBorder(),
            ),
          ),
          const Divider(height: 24),
          _kv('Remaining', '', Formatters.currency(remaining),
              bold: true,
              color: remaining.abs() < 0.001
                  ? AppColors.paid
                  : AppColors.partial),
          _kv('New advance outstanding', '',
              Formatters.currency(newOutstanding)),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _notes,
          decoration: const InputDecoration(
            labelText: 'Notes (optional)',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _saving ? null : () => _sendSlip(e),
          icon: const Icon(Icons.send_outlined),
          label: const Text('Send Salary Slip'),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size.fromHeight(48),
          ),
        ),
        const SizedBox(height: 10),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            minimumSize: const Size.fromHeight(50),
          ),
          onPressed: _saving ? null : () => _save(e),
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Save Payment'),
        ),
      ],
    );
  }

  Widget _card(String title, List<Widget> children) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.cardLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title.toUpperCase(),
                style: const TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.0,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      );

  Widget _kv(String label, String detail, String amount,
          {bool bold = false, Color? color}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  Text(label,
                      style: TextStyle(
                          fontWeight:
                              bold ? FontWeight.w700 : FontWeight.normal)),
                  if (detail.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(detail,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ],
              ),
            ),
            Text(amount,
                style: TextStyle(
                    fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                    color: color)),
          ],
        ),
      );
}
