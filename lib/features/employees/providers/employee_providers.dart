import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/attendance.dart';
import '../models/employee.dart';
import '../repositories/employee_repository.dart';

final employeeRepositoryProvider =
    Provider<EmployeeRepository>((ref) => EmployeeRepository());

/// The month payroll is scoped to, as a first-of-month [DateTime]. The list and
/// detail screens read it to roll up attendance; the month-switcher writes it.
final payrollMonthProvider = StateProvider<DateTime>((ref) {
  final now = DateTime.now();
  return DateTime(now.year, now.month);
});

/// 'yyyy-MM' key for the selected payroll month.
final payrollMonthKeyProvider = Provider<String>((ref) {
  return EmployeeRepository.monthKey(ref.watch(payrollMonthProvider));
});

final employeeSearchProvider = StateProvider<String>((ref) => '');

/// Active employees with the selected month's attendance roll-up.
final employeeListProvider = FutureProvider<List<Employee>>((ref) async {
  final repo = ref.watch(employeeRepositoryProvider);
  final month = ref.watch(payrollMonthKeyProvider);
  final search = ref.watch(employeeSearchProvider);
  return repo.getEmployees(month: month, search: search);
});

/// A single employee with the selected month's roll-up.
final employeeDetailProvider =
    FutureProvider.family<Employee?, int>((ref, id) async {
  final repo = ref.watch(employeeRepositoryProvider);
  final month = ref.watch(payrollMonthKeyProvider);
  return repo.getById(id, month: month);
});

/// One employee's attendance map for the selected month, keyed by 'yyyy-MM-dd'.
final attendanceMonthProvider =
    FutureProvider.family<Map<String, Attendance>, int>((ref, id) async {
  final repo = ref.watch(employeeRepositoryProvider);
  final month = ref.watch(payrollMonthKeyProvider);
  return repo.attendanceForMonth(id, month);
});
