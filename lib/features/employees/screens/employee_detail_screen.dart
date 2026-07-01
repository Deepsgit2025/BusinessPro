import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/responsive.dart';
import '../models/attendance.dart';
import '../models/employee.dart';
import '../models/salary_payment.dart';
import '../providers/employee_providers.dart';
import '../repositories/employee_repository.dart';
import 'add_edit_employee_screen.dart';
import 'give_advance_screen.dart';
import 'salary_payment_screen.dart';

/// Per-employee payroll + attendance. Shows the month's salary summary, a
/// one-tap "log today" strip, and a tappable calendar for any day in the month.
class EmployeeDetailScreen extends ConsumerWidget {
  final int employeeId;
  const EmployeeDetailScreen({super.key, required this.employeeId});

  /// Status order cycled through when a day cell is tapped:
  /// unlogged → present → half → absent → unlogged.
  Future<void> _cycleDay(
    WidgetRef ref,
    String date,
    Attendance? current,
  ) async {
    final repo = ref.read(employeeRepositoryProvider);
    if (current == null) {
      await repo.setAttendance(employeeId, date, AttendanceStatus.present);
    } else {
      switch (current.status) {
        case AttendanceStatus.present:
          await repo.setAttendance(employeeId, date, AttendanceStatus.half);
        case AttendanceStatus.half:
          await repo.setAttendance(employeeId, date, AttendanceStatus.absent);
        case AttendanceStatus.absent:
          await repo.clearAttendance(employeeId, date);
      }
    }
    _refresh(ref);
  }

  Future<void> _setDay(
      WidgetRef ref, String date, AttendanceStatus status) async {
    await ref
        .read(employeeRepositoryProvider)
        .setAttendance(employeeId, date, status);
    _refresh(ref);
  }

  /// Opens the overtime-hours sheet for [date] and saves the result. Overtime
  /// rides on the day's attendance row (it isn't a separate status), so a day
  /// can be present/half *and* carry overtime.
  Future<void> _editOvertime(
    BuildContext context,
    WidgetRef ref,
    String date,
    Attendance? current,
  ) async {
    final emp = ref.read(employeeDetailProvider(employeeId)).valueOrNull;
    final hours = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _OvertimeSheet(
        date: date,
        initialHours: current?.overtimeHours ?? 0,
        rate: emp?.overtimeRate ?? 0,
      ),
    );
    if (hours == null) return; // cancelled
    await ref
        .read(employeeRepositoryProvider)
        .setOvertime(employeeId, date, hours);
    _refresh(ref);
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(attendanceMonthProvider(employeeId));
    ref.invalidate(employeeDetailProvider(employeeId));
    ref.invalidate(employeeListProvider);
    ref.invalidate(advanceLedgerProvider(employeeId));
    ref.invalidate(salaryHistoryProvider(employeeId));
  }

  Future<void> _giveAdvance(
      BuildContext context, WidgetRef ref, Employee e) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => GiveAdvanceScreen(employee: e)),
    );
    if (saved == true) _refresh(ref);
  }

  Future<void> _openSalary(
      BuildContext context, WidgetRef ref, Employee e, DateTime month) async {
    final saved = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => SalaryPaymentScreen(
            employeeId: e.id!, month: EmployeeRepository.monthKey(month)),
      ),
    );
    if (saved == true) _refresh(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final empAsync = ref.watch(employeeDetailProvider(employeeId));
    final attAsync = ref.watch(attendanceMonthProvider(employeeId));
    final month = ref.watch(payrollMonthProvider);

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: const Text('Employee'),
        actions: [
          empAsync.maybeWhen(
            data: (e) => e == null
                ? const SizedBox.shrink()
                : PopupMenuButton<String>(
                    onSelected: (v) {
                      if (v == 'edit') {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AddEditEmployeeScreen(employee: e),
                          ),
                        );
                      } else if (v == 'delete') {
                        _confirmDelete(context, ref, e);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: empAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (employee) {
          if (employee == null) {
            return const Center(child: Text('Employee not found'));
          }
          final att = attAsync.valueOrNull ?? const {};
          final todayKey = DateFormat('yyyy-MM-dd').format(DateTime.now());

          // Shared card instances so the narrow and wide layouts render the
          // exact same widgets (same callbacks/controllers) — only their
          // arrangement differs.
          final summaryCard = _SummaryCard(employee: employee);
          final advanceCard = _AdvanceCard(
            employee: employee,
            onGiveAdvance: () => _giveAdvance(context, ref, employee),
          );
          final logTodayStrip = _LogTodayStrip(
            employeeId: employeeId,
            attendance: att,
            onSet: (date, status) => _setDay(ref, date, status),
            onOvertime: () =>
                _editOvertime(context, ref, todayKey, att[todayKey]),
          );
          final calendarCard = _CalendarCard(
            month: month,
            attendance: att,
            onTapDay: (date, current) => _cycleDay(ref, date, current),
            onLongPressDay: (date, current) =>
                _editOvertime(context, ref, date, current),
          );
          final salaryHistoryCard = _SalaryHistoryCard(employeeId: employeeId);

          // Wide (desktop): centered, capped width with a two-column dashboard —
          // info/action blocks on the left, calendar on the right.
          if (Responsive.isWide(context)) {
            return SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1100),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 5,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              summaryCard,
                              const SizedBox(height: 16),
                              advanceCard,
                              const SizedBox(height: 16),
                              logTodayStrip,
                              const SizedBox(height: 16),
                              salaryHistoryCard,
                            ],
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          flex: 4,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [calendarCard],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }

          // Narrow (phone): unchanged single-column list.
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
            children: [
              summaryCard,
              const SizedBox(height: 16),
              advanceCard,
              const SizedBox(height: 16),
              logTodayStrip,
              const SizedBox(height: 16),
              calendarCard,
              const SizedBox(height: 16),
              salaryHistoryCard,
            ],
          );
        },
      ),
      // "Calculate Salary" is pinned here so it stays visible while the user
      // scrolls the calendar, rather than being buried in the history card.
      bottomNavigationBar: empAsync.maybeWhen(
        data: (employee) => employee == null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  // On wide screens, cap + center the button to the same width
                  // as the content above instead of stretching edge-to-edge.
                  // Align with heightFactor:1 centers horizontally while
                  // shrink-wrapping vertically — a plain Center would expand to
                  // fill the bottom bar's unbounded height and swallow the body.
                  child: Align(
                    alignment: Alignment.center,
                    heightFactor: 1,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth:
                            Responsive.isWide(context) ? 1100 : double.infinity,
                      ),
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 48),
                          backgroundColor: AppColors.primary,
                        ),
                        onPressed: () =>
                            _openSalary(context, ref, employee, month),
                        child: const Text(
                          'Calculate Salary for this Month',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
        orElse: () => null,
      ),
    );
  }

  Future<void> _confirmDelete(
      BuildContext context, WidgetRef ref, Employee e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${e.name}?'),
        content: const Text(
          'The employee and all their attendance records will be removed. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.expense),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(employeeRepositoryProvider).softDelete(e.id!);
      ref.invalidate(employeeListProvider);
      if (context.mounted) Navigator.pop(context);
    }
  }
}

/// Gradient salary summary for the selected month.
class _SummaryCard extends StatelessWidget {
  final Employee employee;
  const _SummaryCard({required this.employee});

  @override
  Widget build(BuildContext context) {
    final initials = employee.name.trim().isEmpty
        ? '?'
        : employee.name
            .trim()
            .split(RegExp(r'\s+'))
            .take(2)
            .map((w) => w[0].toUpperCase())
            .join();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppColors.primaryDark, AppColors.primary, AppColors.accent],
        ),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.3),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 26,
                backgroundColor: Colors.white.withValues(alpha: 0.2),
                child: Text(initials,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(employee.name,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 19,
                            fontWeight: FontWeight.bold)),
                    Text(
                      '${employee.role?.isNotEmpty == true ? '${employee.role}  ·  ' : ''}'
                      '${Formatters.currency(employee.dailyPay)}/day',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'SALARY PAYABLE',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            Formatters.currency(employee.payableThisMonth),
            style: const TextStyle(
                color: Colors.white,
                fontSize: 30,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            '${Formatters.plain(employee.paidDayCount)} paid days  ·  '
            '${employee.presentDays} present, ${employee.halfDays} half, '
            '${employee.absentDays} absent',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85), fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

/// Quick "mark today" row — the daily logging the user does most often.
class _LogTodayStrip extends StatelessWidget {
  final int employeeId;
  final Map<String, Attendance> attendance;
  final void Function(String date, AttendanceStatus status) onSet;
  final VoidCallback onOvertime;
  const _LogTodayStrip({
    required this.employeeId,
    required this.attendance,
    required this.onSet,
    required this.onOvertime,
  });

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final dateKey = DateFormat('yyyy-MM-dd').format(today);
    final todayAtt = attendance[dateKey];
    final current = todayAtt?.status;
    final ot = todayAtt?.overtimeHours ?? 0;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.today_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                'Log today · ${DateFormat('EEE, dd MMM').format(today)}',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final s in AttendanceStatus.values) ...[
                _StatusButton(
                  status: s,
                  selected: current == s,
                  onTap: () => onSet(dateKey, s),
                ),
                if (s != AttendanceStatus.values.last)
                  const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 10),
          // Overtime is additive to the day's status, so it sits on its own row.
          OutlinedButton.icon(
            onPressed: onOvertime,
            icon: Icon(Icons.more_time_outlined,
                size: 18,
                color: ot > 0 ? AppColors.accent : AppColors.textSecondary),
            label: Text(
              ot > 0
                  ? 'Overtime: ${Formatters.plain(ot)} h'
                  : 'Add overtime',
              style: TextStyle(
                color: ot > 0 ? AppColors.accent : AppColors.textSecondary,
                fontWeight: FontWeight.w600,
              ),
            ),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(40),
              side: BorderSide(
                  color: ot > 0 ? AppColors.accent : AppColors.border),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Prominent advance-outstanding card with a "Give Advance" action.
class _AdvanceCard extends StatelessWidget {
  final Employee employee;
  final VoidCallback onGiveAdvance;
  const _AdvanceCard({required this.employee, required this.onGiveAdvance});

  @override
  Widget build(BuildContext context) {
    final outstanding = employee.advanceOutstanding;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('ADVANCE OUTSTANDING',
                    style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textSecondary)),
                const SizedBox(height: 4),
                Text(
                  Formatters.currency(outstanding),
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: outstanding > 0
                        ? AppColors.expense
                        : AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.icon(
            onPressed: onGiveAdvance,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Give Advance'),
            style: FilledButton.styleFrom(backgroundColor: AppColors.primary),
          ),
        ],
      ),
    );
  }
}

/// Salary history list. The "Calculate Salary" action now lives in the screen's
/// pinned bottom bar, so this card is history-only.
class _SalaryHistoryCard extends ConsumerWidget {
  final int employeeId;
  const _SalaryHistoryCard({required this.employeeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final historyAsync = ref.watch(salaryHistoryProvider(employeeId));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              const Text('Salary History',
                  style:
                      TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            ],
          ),
          const SizedBox(height: 4),
          historyAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(12),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('Error: $e'),
            data: (list) {
              if (list.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No salary paid yet',
                      style: TextStyle(color: AppColors.textSecondary)),
                );
              }
              return Column(
                children: [
                  for (final p in list) _SalaryHistoryRow(payment: p),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SalaryHistoryRow extends StatelessWidget {
  final SalaryPayment payment;
  const _SalaryHistoryRow({required this.payment});

  @override
  Widget build(BuildContext context) {
    final monthLabel = () {
      final parts = payment.paymentMonth.split('-');
      if (parts.length != 2) return payment.paymentMonth;
      final y = int.tryParse(parts[0]) ?? 2000;
      final m = int.tryParse(parts[1]) ?? 1;
      return DateFormat('MMM yyyy').format(DateTime(y, m));
    }();
    final splitText = payment.advanceCredited > 0
        ? '${Formatters.currency(payment.cashPaid)} cash + '
            '${Formatters.currency(payment.advanceCredited)} advance'
        : '${Formatters.currency(payment.cashPaid)} cash';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(monthLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                Text(splitText,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Text(Formatters.currency(payment.salaryEarned),
              style: const TextStyle(fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }
}

/// Bottom sheet to enter overtime hours for a day, showing the computed pay.
class _OvertimeSheet extends StatefulWidget {
  final String date;
  final double initialHours;
  final double rate;
  const _OvertimeSheet({
    required this.date,
    required this.initialHours,
    required this.rate,
  });

  @override
  State<_OvertimeSheet> createState() => _OvertimeSheetState();
}

class _OvertimeSheetState extends State<_OvertimeSheet> {
  late final TextEditingController _hours;

  @override
  void initState() {
    super.initState();
    _hours = TextEditingController(
        text: widget.initialHours == 0
            ? ''
            : Formatters.plain(widget.initialHours));
  }

  @override
  void dispose() {
    _hours.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hours = double.tryParse(_hours.text.trim()) ?? 0;
    final pay = hours * widget.rate;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Overtime · ${DateFormat('dd MMM yyyy').format(
              DateTime.tryParse(widget.date) ?? DateTime.now())}',
              style:
                  const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          TextField(
            controller: _hours,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Hours',
              suffixText: 'h',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            widget.rate > 0
                ? 'Overtime pay: ${Formatters.currency(widget.rate)}/hr × '
                    '${Formatters.plain(hours)} = ${Formatters.currency(pay)}'
                : 'Set an overtime rate on the employee to value this.',
            style: const TextStyle(
                fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.primary),
                  onPressed: () => Navigator.pop(context, hours),
                  child: const Text('Confirm'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatusButton extends StatelessWidget {
  final AttendanceStatus status;
  final bool selected;
  final VoidCallback onTap;
  const _StatusButton({
    required this.status,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = _statusColor(status);
    return Expanded(
      child: Material(
        color: selected ? color : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              children: [
                Icon(_statusIcon(status),
                    color: selected ? Colors.white : color, size: 22),
                const SizedBox(height: 4),
                Text(
                  status.label,
                  style: TextStyle(
                    color: selected ? Colors.white : color,
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Tappable month calendar. Each cell cycles present → half → absent → clear.
class _CalendarCard extends StatelessWidget {
  /// Largest a single day cell may grow to (px). Keeps the month compact on
  /// wide screens; below this width cells stay square as on a phone.
  static const double _maxCellSize = 52;

  final DateTime month;
  final Map<String, Attendance> attendance;
  final void Function(String date, Attendance? current) onTapDay;
  final void Function(String date, Attendance? current) onLongPressDay;
  const _CalendarCard({
    required this.month,
    required this.attendance,
    required this.onTapDay,
    required this.onLongPressDay,
  });

  @override
  Widget build(BuildContext context) {
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final firstWeekday = DateTime(month.year, month.month, 1).weekday; // Mon=1
    final leadingBlanks = firstWeekday - 1;
    final today = DateTime.now();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.calendar_month_outlined,
                  size: 18, color: AppColors.primary),
              const SizedBox(width: 8),
              Text(
                DateFormat('MMMM yyyy').format(month),
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const Spacer(),
              const Text('tap to change',
                  style: TextStyle(fontSize: 11, color: AppColors.textHint)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              for (final d in const ['M', 'T', 'W', 'T', 'F', 'S', 'S'])
                Expanded(
                  child: Center(
                    child: Text(d,
                        style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600)),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          // On narrow screens cells stay square (childAspectRatio 1.0), exactly
          // as before. On wide screens a square grid would blow each cell up to
          // (cardWidth / 7) ≈ 200px+, so cap the cell *width* at [_maxCellSize]
          // by widening the aspect ratio — keeping the 7-column grid and every
          // cell's look (colors, today border, ⭐) untouched.
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 6.0;
              final cellWidth =
                  (constraints.maxWidth - spacing * 6) / 7; // 7 cols, 6 gaps
              // Square unless the cell would exceed the cap; then make it wider
              // than tall so its rendered width lands at [_maxCellSize].
              final aspectRatio =
                  cellWidth > _maxCellSize ? cellWidth / _maxCellSize : 1.0;
              return GridView.count(
                crossAxisCount: 7,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: spacing,
                crossAxisSpacing: spacing,
                childAspectRatio: aspectRatio,
                children: [
                  for (var i = 0; i < leadingBlanks; i++)
                    const SizedBox.shrink(),
                  for (var day = 1; day <= daysInMonth; day++)
                    _DayCell(
                      day: day,
                      date: DateTime(month.year, month.month, day),
                      attendance: attendance[
                          '${month.year.toString().padLeft(4, '0')}-'
                          '${month.month.toString().padLeft(2, '0')}-'
                          '${day.toString().padLeft(2, '0')}'],
                      isToday: today.year == month.year &&
                          today.month == month.month &&
                          today.day == day,
                      isFuture: DateTime(month.year, month.month, day).isAfter(
                          DateTime(today.year, today.month, today.day)),
                      onTap: onTapDay,
                      onLongPress: onLongPressDay,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              for (final s in AttendanceStatus.values)
                _LegendDot(color: _statusColor(s), label: s.label),
              const _LegendDot(color: AppColors.accent, label: 'Overtime ⭐'),
            ],
          ),
          const SizedBox(height: 6),
          const Text('Long-press a day to add overtime',
              style: TextStyle(fontSize: 11, color: AppColors.textHint)),
        ],
      ),
    );
  }
}

class _DayCell extends StatelessWidget {
  final int day;
  final DateTime date;
  final Attendance? attendance;
  final bool isToday;
  final bool isFuture;
  final void Function(String date, Attendance? current) onTap;
  final void Function(String date, Attendance? current) onLongPress;
  const _DayCell({
    required this.day,
    required this.date,
    required this.attendance,
    required this.isToday,
    required this.isFuture,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final status = attendance?.status;
    final color = status == null ? null : _statusColor(status);
    final hasOt = attendance?.hasOvertime ?? false;

    return Opacity(
      opacity: isFuture ? 0.35 : 1,
      child: Material(
        color: color ?? AppColors.backgroundLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: isToday
              ? const BorderSide(color: AppColors.primary, width: 1.6)
              : BorderSide.none,
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: isFuture ? null : () => onTap(dateKey, attendance),
          onLongPress: isFuture ? null : () => onLongPress(dateKey, attendance),
          child: Stack(
            children: [
              Center(
                child: Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
                    color:
                        color != null ? Colors.white : AppColors.textPrimary,
                  ),
                ),
              ),
              if (hasOt)
                const Positioned(
                  top: 2,
                  right: 3,
                  child: Text('⭐', style: TextStyle(fontSize: 8)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(label,
            style:
                const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    );
  }
}

Color _statusColor(AttendanceStatus s) => switch (s) {
      AttendanceStatus.present => AppColors.paid,
      AttendanceStatus.half => AppColors.partial,
      AttendanceStatus.absent => AppColors.expense,
    };

IconData _statusIcon(AttendanceStatus s) => switch (s) {
      AttendanceStatus.present => Icons.check_circle_outline,
      AttendanceStatus.half => Icons.timelapse_outlined,
      AttendanceStatus.absent => Icons.cancel_outlined,
    };
