import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/attendance.dart';
import '../models/employee.dart';
import '../providers/employee_providers.dart';

/// Day-at-a-time attendance roster for the whole team. Each employee gets one
/// row with three mutually-exclusive status choices (Full / Half / Absent) plus
/// a *separate*, independent OT toggle. OT only applies to a worked day, so the
/// toggle is shown only when the row is Full or Half; tapping it slides a side
/// panel in from the right (an [AnimatedContainer] that animates from width
/// 0 → 160) for entering overtime hours. One panel open at a time.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

/// Local row status — mirrors [AttendanceStatus]. Overtime is NOT a status: it
/// rides on the day's row independently (tracked via [_overtimeMap]), so a day
/// can be Full+OT or Half+OT.
enum _RowStatus { full, half, absent }

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  DateTime _selectedDate = DateTime.now();
  final Map<int, _RowStatus> _statusMap = {}; // employeeId → status
  final Map<int, double> _overtimeMap = {}; // employeeId → hours
  int? _overtimePanelEmployeeId; // which employee's OT panel is open
  final _overtimeController = TextEditingController();

  String _loadedDateKey = ''; // guards re-priming state on rebuild
  bool _saving = false;

  String get _dateKey => DateFormat('yyyy-MM-dd').format(_selectedDate);

  @override
  void dispose() {
    _overtimeController.dispose();
    super.dispose();
  }

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
      for (final e in employees) {
        final att = existing[e.id];
        if (att == null) {
          _statusMap[e.id!] = _RowStatus.full;
        } else {
          // Status and overtime are independent — a day can be Full/Half *and*
          // carry overtime hours.
          _statusMap[e.id!] = _fromStatus(att.status);
          if (att.overtimeHours > 0) _overtimeMap[e.id!] = att.overtimeHours;
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
      _overtimePanelEmployeeId = null;
      _loadedDateKey = ''; // force re-prime for the new day
    });
  }

  bool get _canGoForward {
    final tomorrow = DateTime.now().add(const Duration(days: 1));
    final next = _selectedDate.add(const Duration(days: 1));
    return next.isBefore(DateTime(tomorrow.year, tomorrow.month, tomorrow.day));
  }

  /// Opens the OT hours panel for [e]. Status is untouched — OT rides alongside
  /// the day's Full/Half status. (Only callable when the row is Full or Half;
  /// the toggle is hidden for Absent.)
  void _openOvertimePanel(Employee e) {
    setState(() {
      _overtimePanelEmployeeId = e.id;
      final hours = _overtimeMap[e.id] ?? 0;
      _overtimeController.text = hours > 0 ? Formatters.plain(hours) : '';
    });
  }

  /// Confirms the entered hours. Entering 0 (or clearing) removes the day's
  /// overtime, leaving the Full/Half status as-is.
  void _confirmOvertime() {
    final id = _overtimePanelEmployeeId;
    if (id == null) return;
    final hours = double.tryParse(_overtimeController.text.trim()) ?? 0;
    setState(() {
      if (hours > 0) {
        _overtimeMap[id] = hours;
      } else {
        _overtimeMap.remove(id);
      }
      _overtimePanelEmployeeId = null;
    });
  }

  void _cancelOvertime() {
    if (_overtimePanelEmployeeId == null) return;
    // OT is independent of status now, so there's nothing to revert — just close.
    setState(() => _overtimePanelEmployeeId = null);
  }

  Future<void> _save(List<Employee> employees) async {
    setState(() => _saving = true);
    final repo = ref.read(employeeRepositoryProvider);
    final key = _dateKey;
    for (final e in employees) {
      final status = _statusMap[e.id] ?? _RowStatus.full;
      // OT only counts on a worked day; an Absent day carries no overtime.
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
              const Divider(height: 1),
              Expanded(
                child: employees.isEmpty
                    ? const Center(child: Text('No employees yet'))
                    : Row(
                        // Pin the (short) table to the top of the Expanded area;
                        // the Row's default center alignment was floating it down
                        // and leaving a large gap under the date row.
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: _buildTable(employees)),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            curve: Curves.easeInOut,
                            width: _overtimePanelEmployeeId != null ? 160 : 0,
                            child: _overtimePanelEmployeeId != null
                                ? _buildOvertimePanel(employees)
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
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
    // Tight bottom padding so the roster table starts right under the date row
    // (no large vertical gap between the two).
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

  Widget _buildTable(List<Employee> employees) {
    return SingleChildScrollView(
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(3),
          1: FlexColumnWidth(1),
          2: FlexColumnWidth(1),
          3: FlexColumnWidth(1),
          4: FlexColumnWidth(1),
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
              _header('OT'),
            ],
          ),
          for (final e in employees)
            TableRow(
              decoration: BoxDecoration(
                color: _overtimePanelEmployeeId == e.id
                    ? AppColors.primary.withValues(alpha: 0.06)
                    : null,
                border: const Border(
                    bottom: BorderSide(color: AppColors.border)),
              ),
              children: [
                Padding(
                  padding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  child: Text(e.name,
                      style: const TextStyle(fontSize: 13),
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
      onTap: () => setState(() {
        _statusMap[e.id!] = status;
        // Absent days carry no overtime — drop any logged OT and close its panel.
        if (status == _RowStatus.absent) {
          _overtimeMap.remove(e.id);
          if (_overtimePanelEmployeeId == e.id) _overtimePanelEmployeeId = null;
        }
      }),
    );
  }

  /// The independent OT toggle. Only meaningful on a worked day, so it's shown
  /// only when the row is Full or Half; for Absent the cell is blank. Tapping it
  /// opens the hours panel. A filled dot + "Nh" caption means OT is logged.
  Widget _overtimeCell(Employee e) {
    final status = _statusMap[e.id] ?? _RowStatus.full;
    if (status == _RowStatus.absent) return const SizedBox.shrink();
    final hours = _overtimeMap[e.id] ?? 0;
    final hasOt = hours > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RadioDot(
          selected: hasOt || _overtimePanelEmployeeId == e.id,
          color: AppColors.accent,
          onTap: () => _openOvertimePanel(e),
        ),
        if (hasOt)
          Text('${Formatters.plain(hours)}h',
              style: const TextStyle(
                  fontSize: 10,
                  color: AppColors.accent,
                  fontWeight: FontWeight.bold)),
      ],
    );
  }

  Widget _buildOvertimePanel(List<Employee> employees) {
    final emp =
        employees.firstWhere((e) => e.id == _overtimePanelEmployeeId);
    final hours = double.tryParse(_overtimeController.text.trim()) ?? 0;
    final pay = hours * emp.overtimeRate;

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.cardLight,
        border: Border(left: BorderSide(color: AppColors.border)),
        boxShadow: [
          BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(-2, 0)),
        ],
      ),
      padding: const EdgeInsets.all(12),
      child: Column(
        // Size to content and top-align (the parent Row is now top-aligned, so
        // a Spacer here would have no bounded height to expand into).
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emp.name,
              style: const TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 13),
              overflow: TextOverflow.ellipsis),
          const Divider(),
          const SizedBox(height: 4),
          const Text('Overtime hours:',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          TextField(
            controller: _overtimeController,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              suffixText: 'hrs',
              border: OutlineInputBorder(),
              contentPadding:
                  EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              isDense: true,
            ),
            style: const TextStyle(fontSize: 14),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          if (hours > 0) ...[
            Text(
              emp.overtimeRate > 0
                  ? '@ ${Formatters.currency(emp.overtimeRate)}/hr'
                  : 'No OT rate set',
              style:
                  const TextStyle(fontSize: 11, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 2),
            Text('= ${Formatters.currency(pay)}',
                style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: AppColors.paid)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 8),
              ),
              onPressed: _confirmOvertime,
              child: const Text('Confirm'),
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _cancelOvertime,
              child: const Text('Cancel'),
            ),
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
/// four selectable cells can live in one [TableRow] without a RadioGroup, and to
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
