import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../models/employee.dart';
import '../providers/employee_providers.dart';
import 'add_edit_employee_screen.dart';
import 'attendance_screen.dart';
import 'employee_detail_screen.dart';

/// Employee module landing — a clean, contacts-style roster. Each row is just
/// the employee's name; tapping it opens their detail (attendance + salary).
/// Two actions sit pinned at the bottom: open the day's Attendance roster, or
/// add a new employee.
class EmployeesListScreen extends ConsumerStatefulWidget {
  const EmployeesListScreen({super.key});

  @override
  ConsumerState<EmployeesListScreen> createState() =>
      _EmployeesListScreenState();
}

class _EmployeesListScreenState extends ConsumerState<EmployeesListScreen> {
  bool _searching = false;
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _openAdd() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddEditEmployeeScreen()),
    );
  }

  void _openDetail(Employee e) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => EmployeeDetailScreen(employeeId: e.id!)),
    );
  }

  void _openAttendance() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AttendanceScreen()),
    );
  }

  void _stopSearching() {
    setState(() => _searching = false);
    _searchController.clear();
    ref.read(employeeSearchProvider.notifier).state = '';
  }

  @override
  Widget build(BuildContext context) {
    final employeesAsync = ref.watch(employeeListProvider);

    // The search field lives on the purple AppBar, so its text must use the
    // AppBar's foreground colour (white in both light & dark) — NOT onSurface,
    // which is dark and would vanish against the purple bar. Bound to the theme
    // so it tracks the AppBar if the brand colour ever changes.
    final onAppBar = Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).colorScheme.onPrimary;

    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: TextStyle(color: onAppBar, fontSize: 18),
                cursorColor: onAppBar,
                decoration: InputDecoration(
                  hintText: 'Search employees…',
                  hintStyle: TextStyle(color: onAppBar.withValues(alpha: 0.7)),
                  // The global inputDecorationTheme fills fields white with a
                  // rounded border — on the purple AppBar that paints a white box
                  // over white text (invisible). Force a transparent, border-less
                  // field so the text reads against the bar.
                  filled: false,
                  isCollapsed: true,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
                onChanged: (v) =>
                    ref.read(employeeSearchProvider.notifier).state = v,
              )
            : const Text('Employees'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: _searching ? _stopSearching : () => setState(() => _searching = true),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(employeeListProvider),
        child: employeesAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (employees) {
            if (employees.isEmpty) {
              return _EmptyEmployees(onAdd: _openAdd);
            }
            return ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: employees.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, indent: 72),
              itemBuilder: (_, i) {
                final e = employees[i];
                return _EmployeeTile(employee: e, onTap: () => _openDetail(e));
              },
            );
          },
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _openAttendance,
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('Attendance'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    foregroundColor: AppColors.primary,
                    side: const BorderSide(color: AppColors.primary),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _openAdd,
                  icon: const Icon(Icons.person_add_alt_1, color: Colors.white),
                  label: const Text('Add Employee',
                      style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: AppColors.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A single contacts-style row: avatar initial + name + chevron. Nothing else.
class _EmployeeTile extends StatelessWidget {
  final Employee employee;
  final VoidCallback onTap;
  const _EmployeeTile({required this.employee, required this.onTap});

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

    return ListTile(
      tileColor: AppColors.cardLight,
      leading: Container(
        width: 44,
        height: 44,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            colors: [AppColors.primary, AppColors.accent],
          ),
        ),
        alignment: Alignment.center,
        child: Text(
          initials,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 15,
          ),
        ),
      ),
      title: Row(
        children: [
          // Name flexes and ellipsizes so a long name never pushes the counts
          // off the row — they stay on the same line.
          Flexible(
            child: Text(
              employee.name,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Present ${employee.presentDays}  '
            'Half ${employee.halfDays}  '
            'Absent ${employee.absentDays}',
            style: const TextStyle(
                fontSize: 11.5, color: AppColors.textSecondary),
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right, color: AppColors.textHint),
      onTap: onTap,
    );
  }
}

class _EmptyEmployees extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyEmployees({required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        const SizedBox(height: 80),
        Center(
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
      ],
    );
  }
}
