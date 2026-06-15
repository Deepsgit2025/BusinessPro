import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Transaction;

import '../../../core/database/database_helper.dart';
import '../models/attendance.dart';
import '../models/employee.dart';
import '../models/employee_advance.dart';
import '../models/salary_payment.dart';

/// Data access for employees and their attendance. Employees are soft-deleted
/// (is_active = 0); attendance rows are hard data, cascade-deleted with the
/// employee.
class EmployeeRepository {
  static const _businessId = 1;

  /// A `yyyy-MM` month key (e.g. '2026-06') used to scope payroll queries.
  static String monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  /// Active employees, name-sorted, each joined with the [month] attendance
  /// roll-up (present/half/absent counts + payable). [month] is a 'yyyy-MM' key.
  /// [search] matches name, role, or phone.
  Future<List<Employee>> getEmployees({
    required String month,
    String? search,
  }) async {
    final db = await DatabaseHelper.database;

    final where = <String>['e.business_id = ?', 'e.is_active = 1'];
    final args = <Object?>[_businessId];

    if (search != null && search.trim().isNotEmpty) {
      where.add('(e.name LIKE ? OR e.role LIKE ? OR e.phone LIKE ?)');
      final like = '%${search.trim()}%';
      args..add(like)..add(like)..add(like);
    }

    // Per-employee roll-up of the target month's attendance. day_value is the
    // snapshotted pay weight, so payable = daily_pay × Σ day_value.
    final rows = await db.rawQuery('''
      SELECT e.*,
        COALESCE(a.present_days, 0)      AS present_days,
        COALESCE(a.half_days, 0)         AS half_days,
        COALESCE(a.absent_days, 0)       AS absent_days,
        COALESCE(a.ot_hours, 0)          AS overtime_hours_total,
        COALESCE(a.day_total, 0) * e.daily_pay
          + COALESCE(a.ot_hours, 0) * e.overtime_rate AS payable_this_month
      FROM employees e
      LEFT JOIN (
        SELECT employee_id,
          SUM(CASE WHEN status = 'present' THEN 1 ELSE 0 END) AS present_days,
          SUM(CASE WHEN status = 'half'    THEN 1 ELSE 0 END) AS half_days,
          SUM(CASE WHEN status = 'absent'  THEN 1 ELSE 0 END) AS absent_days,
          SUM(day_value)                                      AS day_total,
          SUM(COALESCE(overtime_hours, 0))                    AS ot_hours
        FROM attendance
        WHERE substr(date, 1, 7) = ?
        GROUP BY employee_id
      ) a ON a.employee_id = e.id
      WHERE ${where.join(' AND ')}
      ORDER BY e.name COLLATE NOCASE ASC
    ''', [month, ...args]);

    return rows.map(Employee.fromMap).toList();
  }

  Future<Employee?> getById(int id, {required String month}) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT e.*,
        COALESCE(a.present_days, 0)      AS present_days,
        COALESCE(a.half_days, 0)         AS half_days,
        COALESCE(a.absent_days, 0)       AS absent_days,
        COALESCE(a.ot_hours, 0)          AS overtime_hours_total,
        COALESCE(a.day_total, 0) * e.daily_pay
          + COALESCE(a.ot_hours, 0) * e.overtime_rate AS payable_this_month
      FROM employees e
      LEFT JOIN (
        SELECT employee_id,
          SUM(CASE WHEN status = 'present' THEN 1 ELSE 0 END) AS present_days,
          SUM(CASE WHEN status = 'half'    THEN 1 ELSE 0 END) AS half_days,
          SUM(CASE WHEN status = 'absent'  THEN 1 ELSE 0 END) AS absent_days,
          SUM(day_value)                                      AS day_total,
          SUM(COALESCE(overtime_hours, 0))                    AS ot_hours
        FROM attendance
        WHERE substr(date, 1, 7) = ?
        GROUP BY employee_id
      ) a ON a.employee_id = e.id
      WHERE e.id = ?
    ''', [month, id]);
    return rows.isEmpty ? null : Employee.fromMap(rows.first);
  }

  /// Inserts an employee. When [openingAdvance] > 0, the row is created with
  /// that advance already given and a matching 'given' ledger entry is appended,
  /// so the outstanding advance shows immediately.
  Future<int> insert(Employee e, {double openingAdvance = 0}) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    return db.transaction((txn) async {
      final id = await txn.insert('employees', {
        ...e.toMap(),
        'advance_given': openingAdvance > 0 ? openingAdvance : 0,
        'advance_paid': 0,
        'created_at': now,
        'updated_at': now,
      });
      if (openingAdvance > 0) {
        await txn.insert('employee_advances', {
          'business_id': _businessId,
          'employee_id': id,
          'amount': openingAdvance,
          'type': AdvanceType.given.db,
          'notes': 'Opening advance',
          'advance_date': _today(),
        });
      }
      return id;
    });
  }

  Future<void> update(Employee e) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'employees',
      {...e.toMap(), 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [e.id],
    );
  }

  Future<void> softDelete(int id) async {
    final db = await DatabaseHelper.database;
    await db.update(
      'employees',
      {'is_active': 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ───────────────────────── Attendance ─────────────────────────

  /// Logs (or overwrites) one employee's status for [date]. The UNIQUE
  /// constraint on (employee_id, date) makes this an upsert, so re-tapping a
  /// day's status simply corrects it. [date] is a 'yyyy-MM-dd' string.
  Future<void> setAttendance(
    int employeeId,
    String date,
    AttendanceStatus status, {
    double? overtimeHours,
    String? note,
  }) async {
    final db = await DatabaseHelper.database;
    final existing = await db.query(
      'attendance',
      where: 'employee_id = ? AND date = ?',
      whereArgs: [employeeId, date],
      limit: 1,
    );
    // Overtime rides on the day's row. When the caller doesn't pass it,
    // preserve any hours already logged for the day rather than wiping them.
    final ot = overtimeHours ??
        (existing.isEmpty
            ? 0.0
            : (existing.first['overtime_hours'] as num?)?.toDouble() ?? 0.0);
    final values = {
      'employee_id': employeeId,
      'date': date,
      'status': status.db,
      'day_value': status.dayValue,
      'overtime_hours': ot,
      'note': note,
    };
    if (existing.isEmpty) {
      await db.insert('attendance', values);
    } else {
      await db.update('attendance', values,
          where: 'id = ?', whereArgs: [existing.first['id']]);
    }
  }

  /// Sets just the overtime hours for a day, leaving status as-is (defaulting to
  /// present when the day isn't logged yet). Clearing to 0 removes the overtime
  /// but keeps the day's present/half/absent log.
  Future<void> setOvertime(
      int employeeId, String date, double hours) async {
    final db = await DatabaseHelper.database;
    final existing = await db.query(
      'attendance',
      where: 'employee_id = ? AND date = ?',
      whereArgs: [employeeId, date],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('attendance', {
        'employee_id': employeeId,
        'date': date,
        'status': AttendanceStatus.present.db,
        'day_value': AttendanceStatus.present.dayValue,
        'overtime_hours': hours,
      });
    } else {
      await db.update('attendance', {'overtime_hours': hours},
          where: 'id = ?', whereArgs: [existing.first['id']]);
    }
  }

  /// Every active employee's attendance row for a single [date] ('yyyy-MM-dd'),
  /// keyed by employee id, so the roster screen can prime its state for the day.
  Future<Map<int, Attendance>> attendanceForDate(String date) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT a.* FROM attendance a
      JOIN employees e ON e.id = a.employee_id
      WHERE a.date = ? AND e.business_id = ? AND e.is_active = 1
    ''', [date, _businessId]);
    return {
      for (final r in rows) r['employee_id'] as int: Attendance.fromMap(r),
    };
  }

  /// Removes a day's log entirely (back to "not logged").
  Future<void> clearAttendance(int employeeId, String date) async {
    final db = await DatabaseHelper.database;
    await db.delete('attendance',
        where: 'employee_id = ? AND date = ?', whereArgs: [employeeId, date]);
  }

  /// Every attendance row for one employee in [month] ('yyyy-MM'), keyed by
  /// 'yyyy-MM-dd' date for quick day-cell lookup.
  Future<Map<String, Attendance>> attendanceForMonth(
      int employeeId, String month) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'attendance',
      where: 'employee_id = ? AND substr(date, 1, 7) = ?',
      whereArgs: [employeeId, month],
    );
    return {
      for (final r in rows)
        r['date'] as String: Attendance.fromMap(r),
    };
  }

  // ───────────────────────── Advances ─────────────────────────

  /// Records an advance *given* to the employee: bumps `advance_given` on the
  /// employees row and appends a 'given' ledger entry. [date] is 'yyyy-MM-dd'.
  Future<void> giveAdvance(
    int employeeId,
    double amount, {
    String? notes,
    String? date,
  }) async {
    final db = await DatabaseHelper.database;
    final day = date ?? _today();
    await db.transaction((txn) async {
      await txn.rawUpdate(
        "UPDATE employees SET advance_given = advance_given + ?, "
        "updated_at = datetime('now') WHERE id = ?",
        [amount, employeeId],
      );
      await txn.insert('employee_advances', {
        'business_id': _businessId,
        'employee_id': employeeId,
        'amount': amount,
        'type': AdvanceType.given.db,
        'notes': notes,
        'advance_date': day,
      });
    });
  }

  /// Advance ledger for one employee, newest first.
  Future<List<EmployeeAdvance>> advancesFor(int employeeId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'employee_advances',
      where: 'employee_id = ?',
      whereArgs: [employeeId],
      orderBy: 'advance_date DESC, id DESC',
    );
    return rows.map(EmployeeAdvance.fromMap).toList();
  }

  // ───────────────────────── Salary payments ─────────────────────────

  /// Records a salary payout. In one transaction it inserts the snapshot row,
  /// and — when some salary was applied against the advance — bumps the
  /// employee's `advance_paid` and appends a 'credited' ledger entry. The
  /// attendance counts / overtime on [payment] are the figures shown to the
  /// user at save time, so the payslip stays stable if attendance changes later.
  Future<int> recordSalaryPayment(SalaryPayment payment) async {
    final db = await DatabaseHelper.database;
    return db.transaction((txn) async {
      final id = await txn.insert('salary_payments', payment.toMap());
      if (payment.advanceCredited > 0) {
        await txn.rawUpdate(
          "UPDATE employees SET advance_paid = advance_paid + ?, "
          "updated_at = datetime('now') WHERE id = ?",
          [payment.advanceCredited, payment.employeeId],
        );
        await txn.insert('employee_advances', {
          'business_id': _businessId,
          'employee_id': payment.employeeId,
          'amount': payment.advanceCredited,
          'type': AdvanceType.credited.db,
          'notes': 'Recovered from ${payment.paymentMonth} salary',
          'advance_date': payment.paymentDate,
        });
      }
      // Cap salary-slip history at the 12 most recent payments per employee.
      // Same ordering as salaryHistory() (newest month first), so we keep the
      // top 12 ids and drop anything older. Runs in the same transaction as the
      // insert; touches ONLY salary_payments — the advances ledger is never
      // pruned, as it's a running balance.
      await _pruneSalaryHistory(txn, payment.employeeId);
      return id;
    });
  }

  /// Deletes all but the latest 12 [salary_payments] rows for [employeeId],
  /// within the caller's transaction. Never touches [employee_advances].
  Future<void> _pruneSalaryHistory(Transaction txn, int employeeId) async {
    await txn.rawDelete('''
      DELETE FROM salary_payments
      WHERE employee_id = ?
        AND id NOT IN (
          SELECT id FROM salary_payments
          WHERE employee_id = ?
          ORDER BY payment_month DESC, id DESC
          LIMIT 12
        )
    ''', [employeeId, employeeId]);
  }

  /// Salary payout history for one employee, newest month first.
  Future<List<SalaryPayment>> salaryHistory(int employeeId) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'salary_payments',
      where: 'employee_id = ?',
      whereArgs: [employeeId],
      orderBy: 'payment_month DESC, id DESC',
    );
    return rows.map(SalaryPayment.fromMap).toList();
  }

  /// The salary payment already recorded for [month] ('yyyy-MM'), or null. Used
  /// to show "already paid" and avoid a double payout.
  Future<SalaryPayment?> salaryForMonth(int employeeId, String month) async {
    final db = await DatabaseHelper.database;
    final rows = await db.query(
      'salary_payments',
      where: 'employee_id = ? AND payment_month = ?',
      whereArgs: [employeeId, month],
      limit: 1,
    );
    return rows.isEmpty ? null : SalaryPayment.fromMap(rows.first);
  }

  static String _today() {
    final d = DateTime.now();
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }
}
