import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/attendance.dart';
import '../models/employee.dart';
import '../providers/employee_providers.dart';
import 'add_edit_employee_screen.dart';

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

  void _refresh(WidgetRef ref) {
    ref.invalidate(attendanceMonthProvider(employeeId));
    ref.invalidate(employeeDetailProvider(employeeId));
    ref.invalidate(employeeListProvider);
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
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
            children: [
              _SummaryCard(employee: employee),
              const SizedBox(height: 16),
              _LogTodayStrip(
                employeeId: employeeId,
                attendance: att,
                onSet: (date, status) => _setDay(ref, date, status),
              ),
              const SizedBox(height: 16),
              _CalendarCard(
                month: month,
                attendance: att,
                onTapDay: (date, current) => _cycleDay(ref, date, current),
              ),
            ],
          );
        },
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
  const _LogTodayStrip({
    required this.employeeId,
    required this.attendance,
    required this.onSet,
  });

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();
    final dateKey = DateFormat('yyyy-MM-dd').format(today);
    final current = attendance[dateKey]?.status;

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
  final DateTime month;
  final Map<String, Attendance> attendance;
  final void Function(String date, Attendance? current) onTapDay;
  const _CalendarCard({
    required this.month,
    required this.attendance,
    required this.onTapDay,
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
          GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            children: [
              for (var i = 0; i < leadingBlanks; i++) const SizedBox.shrink(),
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
                  isFuture: DateTime(month.year, month.month, day)
                      .isAfter(DateTime(today.year, today.month, today.day)),
                  onTap: onTapDay,
                ),
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              for (final s in AttendanceStatus.values)
                _LegendDot(color: _statusColor(s), label: s.label),
            ],
          ),
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
  const _DayCell({
    required this.day,
    required this.date,
    required this.attendance,
    required this.isToday,
    required this.isFuture,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final status = attendance?.status;
    final color = status == null ? null : _statusColor(status);

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
          child: Center(
            child: Text(
              '$day',
              style: TextStyle(
                fontSize: 13,
                fontWeight: isToday ? FontWeight.bold : FontWeight.w500,
                color: color != null ? Colors.white : AppColors.textPrimary,
              ),
            ),
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
