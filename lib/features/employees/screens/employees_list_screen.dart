import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/employee.dart';
import '../providers/employee_providers.dart';
import 'add_edit_employee_screen.dart';
import 'employee_detail_screen.dart';

/// Employee module landing — a futuristic payroll dashboard. A month switcher
/// scopes the attendance roll-up; the header shows the month's total payable;
/// each card opens the employee's attendance calendar.
class EmployeesListScreen extends ConsumerWidget {
  const EmployeesListScreen({super.key});

  void _openAdd(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddEditEmployeeScreen()),
    );
  }

  void _openDetail(BuildContext context, Employee e) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EmployeeDetailScreen(employeeId: e.id!)),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final employeesAsync = ref.watch(employeeListProvider);

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(title: const Text('Employees')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        onPressed: () => _openAdd(context),
        icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
        label: const Text('Add', style: TextStyle(color: Colors.white)),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(employeeListProvider),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
          children: [
            const _PayrollHeader(),
            const SizedBox(height: 16),
            employeesAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.only(top: 64),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.only(top: 48),
                child: Center(child: Text('Error: $e')),
              ),
              data: (employees) {
                if (employees.isEmpty) {
                  return _EmptyEmployees(onAdd: () => _openAdd(context));
                }
                return Column(
                  children: [
                    for (final e in employees)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _EmployeeCard(
                          employee: e,
                          onTap: () => _openDetail(context, e),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Gradient hero card: month switcher + total monthly payable + headcount.
class _PayrollHeader extends ConsumerWidget {
  const _PayrollHeader();

  void _shiftMonth(WidgetRef ref, int delta) {
    final m = ref.read(payrollMonthProvider);
    ref.read(payrollMonthProvider.notifier).state =
        DateTime(m.year, m.month + delta);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final month = ref.watch(payrollMonthProvider);
    final employeesAsync = ref.watch(employeeListProvider);

    final total = employeesAsync.maybeWhen(
      data: (list) =>
          list.fold<double>(0, (s, e) => s + e.payableThisMonth),
      orElse: () => 0.0,
    );
    final headcount = employeesAsync.maybeWhen(
      data: (list) => list.length,
      orElse: () => 0,
    );

    final now = DateTime.now();
    final isCurrentMonth = month.year == now.year && month.month == now.month;

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
            color: AppColors.primary.withValues(alpha: 0.35),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Month switcher.
          Row(
            children: [
              _RoundIconButton(
                icon: Icons.chevron_left,
                onTap: () => _shiftMonth(ref, -1),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    DateFormat('MMMM yyyy').format(month),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ),
              _RoundIconButton(
                icon: Icons.chevron_right,
                // Don't navigate into future months.
                onTap: isCurrentMonth ? null : () => _shiftMonth(ref, 1),
              ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            'PAYROLL THIS MONTH',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            Formatters.currency(total),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              const Icon(Icons.groups_outlined, color: Colors.white70, size: 16),
              const SizedBox(width: 6),
              Text(
                '$headcount ${headcount == 1 ? 'employee' : 'employees'}',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _RoundIconButton({required this.icon, this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: onTap == null ? 0.06 : 0.18),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon,
              color: Colors.white.withValues(alpha: onTap == null ? 0.4 : 1),
              size: 22),
        ),
      ),
    );
  }
}

class _EmployeeCard extends StatelessWidget {
  final Employee employee;
  final VoidCallback onTap;
  const _EmployeeCard({required this.employee, required this.onTap});

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
      decoration: BoxDecoration(
        color: AppColors.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          colors: [AppColors.primary, AppColors.accent],
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        initials,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            employee.name,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${employee.role?.isNotEmpty == true ? '${employee.role}  ·  ' : ''}'
                            '${Formatters.currency(employee.dailyPay)}/day',
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: AppColors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          Formatters.currency(employee.payableThisMonth),
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppColors.primary,
                          ),
                        ),
                        const Text(
                          'payable',
                          style: TextStyle(
                              fontSize: 10.5, color: AppColors.textHint),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    _StatPill(
                      color: AppColors.paid,
                      icon: Icons.check_circle_outline,
                      value: '${employee.presentDays}',
                      label: 'Present',
                    ),
                    const SizedBox(width: 8),
                    _StatPill(
                      color: AppColors.partial,
                      icon: Icons.timelapse_outlined,
                      value: '${employee.halfDays}',
                      label: 'Half',
                    ),
                    const SizedBox(width: 8),
                    _StatPill(
                      color: AppColors.expense,
                      icon: Icons.cancel_outlined,
                      value: '${employee.absentDays}',
                      label: 'Absent',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatPill extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String value;
  final String label;
  const _StatPill({
    required this.color,
    required this.icon,
    required this.value,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 18),
            const SizedBox(height: 2),
            Text(
              value,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 15),
            ),
            Text(
              label,
              style: const TextStyle(
                  fontSize: 10, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyEmployees extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyEmployees({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.primary.withValues(alpha: 0.08),
              ),
              child: const Icon(Icons.groups_2_outlined,
                  size: 48, color: AppColors.primary),
            ),
            const SizedBox(height: 20),
            const Text('No employees yet',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            const Text(
              'Add your first employee to start\ntracking attendance and salary',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 22),
            ElevatedButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add Employee'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
