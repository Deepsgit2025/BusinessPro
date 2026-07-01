import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/attendance.dart';
import '../models/employee.dart';
import '../providers/employee_providers.dart';

/// Day-at-a-time attendance roster for the whole team. Each employee gets one
/// row with three mutually-exclusive status choices (Full / Half / Absent) plus
/// a *separate*, independent overtime adjustment stepped with − / + buttons.
///
/// The overtime value is **signed**: positive hours are overtime worked, and a
/// negative value records an early-leave (the employee left before time). At
/// month-end the signed hours net against each other, so an early-leave is
/// deducted from overtime — the payroll roll-up already sums `overtime_hours`,
/// so no calculation changes are needed here.
///
/// A **Holiday** toggle at the top marks every employee Absent in one tap (still
/// individually editable afterwards), so a shop holiday isn't entered row-by-row.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

/// Local row status — mirrors [AttendanceStatus]. Overtime is NOT a status: it
/// rides on the day's row independently (tracked via [_overtimeMap]), so a day
/// can be Full+OT or Half+OT (or carry a negative early-leave adjustment).
enum _RowStatus { full, half, absent }

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  /// Each − / + tap nudges the overtime adjustment by this many hours.
  static const _otStep = 0.5;

  DateTime _selectedDate = DateTime.now();
  final Map<int, _RowStatus> _statusMap = {}; // employeeId → status
  final Map<int, double> _overtimeMap = {}; // employeeId → signed hours
  bool _holiday = false; // "everyone absent today" convenience toggle

  String _loadedDateKey = ''; // guards re-priming state on rebuild
  bool _saving = false;

  String get _dateKey => DateFormat('yyyy-MM-dd').format(_selectedDate);

  /// Pulls existing rows for the selected day and seeds the local maps. Runs once
  /// per date (guarded by [_loadedDateKey]); employees with no row default to
  /// "full" (present) on save.
  Future<void> _primeForDate(List<Employee> employees) async {
    final key = _dateKey;
    if (_loadedDateKey == key) return;
    _loadedDateKey = key;
    final existing =
        await ref.read(employeeRepositoryProvider).attendanceForDate(key);
    if (!mounted) return;
    setState(() {
      _statusMap.clear();
      _overtimeMap.clear();
      _holiday = false; // the toggle never carries across days
      for (final e in employees) {
        final att = existing[e.id];
        if (att == null) {
          _statusMap[e.id!] = _RowStatus.full;
        } else {
          // Status and overtime are independent — a day can be Full/Half *and*
          // carry an overtime / early-leave adjustment.
          _statusMap[e.id!] = _fromStatus(att.status);
          if (att.overtimeHours != 0) _overtimeMap[e.id!] = att.overtimeHours;
        }
      }
    });
  }

  _RowStatus _fromStatus(AttendanceStatus s) => switch (s) {
        AttendanceStatus.present => _RowStatus.full,
        AttendanceStatus.half => _RowStatus.half,
        AttendanceStatus.absent => _RowStatus.absent,
      };

  AttendanceStatus _toStatus(_RowStatus s) => switch (s) {
        _RowStatus.full => AttendanceStatus.present,
        _RowStatus.half => AttendanceStatus.half,
        _RowStatus.absent => AttendanceStatus.absent,
      };

  void _shiftDay(int delta) {
    setState(() {
      _selectedDate = _selectedDate.add(Duration(days: delta));
      _loadedDateKey = ''; // force re-prime for the new day
    });
  }

  bool get _canGoForward {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final next = _selectedDate.add(const Duration(days: 1));
    return next.isBefore(DateTime(tomorrow.year, tomorrow.month, tomorrow.day));
  }

  /// Holiday toggle. ON marks everyone Absent (clearing any overtime, since an
  /// Absent day carries none). OF re-primes the day from the DB, reverting rows
  /// to their saved/default state.
  void _setHoliday(bool on, List<Employee> employees) {
    if (on) {
      setState(() {
        _holiday = true;
        for (final e in employees) {
          _statusMap[e.id!] = _RowStatus.absent;
        }
        _overtimeMap.clear();
      });
    } else {
      // Revert: re-prime from the DB for this day.
      setState(() {
        _holiday = false;
        _loadedDateKey = '';
      });
      _primeForDate(employees);
    }
  }

  void _setStatus(Employee e, _RowStatus status) {
    setState(() {
      _statusMap[e.id!] = status;
      // Absent days carry no overtime — drop any logged adjustment.
      if (status == _RowStatus.absent) {
        _overtimeMap.remove(e.id);
      } else if (_holiday) {
        // Flipping anyone back to a worked day means it's no longer a clean
        // "everyone absent" holiday — reflect that in the toggle.
        _holiday = false;
      }
    });
  }

  /// Steps an employee's signed overtime adjustment by [delta] hours. The value
  /// may go negative (early-leave). No-op for an Absent row (an absent day has no
  /// hours). Values within a hair of zero collapse to "no adjustment".
  void _adjustOvertime(Employee e, double delta) {
    if ((_statusMap[e.id] ?? _RowStatus.full) == _RowStatus.absent) return;
    setState(() {
      final next = (_overtimeMap[e.id] ?? 0) + delta;
      if (next.abs() < 0.001) {
        _overtimeMap.remove(e.id);
      } else {
        _overtimeMap[e.id!] = next;
      }
    });
  }

  Future<void> _save(List<Employee> employees) async {
    setState(() => _saving = true);
    final repo = ref.read(employeeRepositoryProvider);
    final key = _dateKey;
    for (final e in employees) {
      final status = _statusMap[e.id] ?? _RowStatus.full;
      // OT only counts on a worked day; an Absent day carries no adjustment.
      final ot =
          status == _RowStatus.absent ? 0.0 : (_overtimeMap[e.id] ?? 0);
      await repo.setAttendance(e.id!, key, _toStatus(status),
          overtimeHours: ot);
    }
    ref.invalidate(employeeListProvider);
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Attendance saved for ${DateFormat('dd MMM').format(_selectedDate)} ✓'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final employeesAsync = ref.watch(employeeListProvider);
    return Scaffold(
      backgroundColor: AppColors.backgroundLight,
      appBar: AppBar(title: const Text('Attendance')),
      body: employeesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (employees) {
          // Seed local state for the day on first build / after a date change.
          _primeForDate(employees);
          return Column(
            children: [
              _buildDateNav(),
              if (employees.isNotEmpty) _buildHolidayToggle(employees),
              const Divider(height: 1),
              Expanded(
                child: employees.isEmpty
                    ? const Center(child: Text('No employees yet'))
                    : _buildTable(employees),
              ),
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                        backgroundColor: AppColors.primary,
                        foregroundColor: Colors.white,
                      ),
                      onPressed: (employees.isEmpty || _saving)
                          ? null
                          : () => _save(employees),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Text('Save Attendance'),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDateNav() {
    // Tight bottom padding so the roster starts right under the date row.
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => _shiftDay(-1),
          ),
          Text(
            DateFormat('dd MMMM yyyy').format(_selectedDate),
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: _canGoForward ? () => _shiftDay(1) : null,
          ),
        ],
      ),
    );
  }

  /// The "shop holiday" convenience toggle — one tap marks everyone Absent.
  Widget _buildHolidayToggle(List<Employee> employees) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: _holiday
            ? AppColors.expense.withValues(alpha: 0.08)
            : AppColors.cardLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _holiday ? AppColors.expense : AppColors.border,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.beach_access_outlined,
              size: 20,
              color: _holiday ? AppColors.expense : AppColors.textSecondary),
          const SizedBox(width: 10),
          const Expanded(
            child: Text('Holiday — mark everyone absent',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          Switch(
            value: _holiday,
            activeThumbColor: AppColors.expense,
            onChanged: (v) => _setHoliday(v, employees),
          ),
        ],
      ),
    );
  }

  Widget _buildTable(List<Employee> employees) {
    return SingleChildScrollView(
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(2.4),
          1: FlexColumnWidth(1),
          2: FlexColumnWidth(1),
          3: FlexColumnWidth(1),
          4: FlexColumnWidth(2),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          TableRow(
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border)),
            ),
            children: [
              _header('Name'),
              _header('Full'),
              _header('Half'),
              _header('Absent'),
              _header('OT / Early'),
            ],
          ),
          for (final e in employees)
            TableRow(
              decoration: const BoxDecoration(
                border:
                    Border(bottom: BorderSide(color: AppColors.border)),
              ),
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  child: Text(e.name,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                      overflow: TextOverflow.ellipsis),
                ),
                _radioCell(e, _RowStatus.full),
                _radioCell(e, _RowStatus.half),
                _radioCell(e, _RowStatus.absent),
                _overtimeCell(e),
              ],
            ),
        ],
      ),
    );
  }

  Widget _header(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: AppColors.textSecondary)),
      );

  Widget _radioCell(Employee e, _RowStatus status) {
    final selected = (_statusMap[e.id] ?? _RowStatus.full) == status;
    return _RadioDot(
      selected: selected,
      color: _statusColor(status),
      onTap: () => _setStatus(e, status),
    );
  }

  /// The signed overtime stepper: `−  +1.5h  +`. Only meaningful on a worked day,
  /// so for an Absent row the cell is blank. Positive (accent) = overtime worked,
  /// negative (expense red) = early-leave; both net into the month's payroll.
  Widget _overtimeCell(Employee e) {
    final status = _statusMap[e.id] ?? _RowStatus.full;
    if (status == _RowStatus.absent) return const SizedBox.shrink();
    final hours = _overtimeMap[e.id] ?? 0;
    final color = hours > 0
        ? AppColors.accent
        : (hours < 0 ? AppColors.expense : AppColors.textHint);
    final label =
        hours == 0 ? '0h' : '${hours > 0 ? '+' : ''}${Formatters.plain(hours)}h';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _StepButton(
            icon: Icons.remove,
            onTap: () => _adjustOvertime(e, -_otStep),
          ),
          SizedBox(
            width: 42,
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold, color: color),
            ),
          ),
          _StepButton(
            icon: Icons.add,
            onTap: () => _adjustOvertime(e, _otStep),
          ),
        ],
      ),
    );
  }

  Color _statusColor(_RowStatus s) => switch (s) {
        _RowStatus.full => AppColors.paid,
        _RowStatus.half => AppColors.partial,
        _RowStatus.absent => AppColors.expense,
      };
}

/// A compact, tappable radio indicator. Used instead of the Material [Radio] so
/// three selectable cells can live in one [TableRow] without a RadioGroup, and to
/// stay narrow enough for a 360px-wide screen.
class _RadioDot extends StatelessWidget {
  final bool selected;
  final Color color;
  final VoidCallback onTap;
  const _RadioDot({
    required this.selected,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Center(
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? color : AppColors.textHint,
                width: 2,
              ),
            ),
            child: selected
                ? Center(
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration:
                          BoxDecoration(shape: BoxShape.circle, color: color),
                    ),
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// A small round − / + button for the overtime stepper. Kept compact so the
/// `−  value  +` trio fits the narrow OT column on a phone.
class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _StepButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkResponse(
      onTap: onTap,
      radius: 18,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.border),
          color: AppColors.cardLight,
        ),
        child: Icon(icon, size: 16, color: AppColors.primary),
      ),
    );
  }
}
