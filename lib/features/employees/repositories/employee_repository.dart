import '../../../core/database/database_helper.dart';
import '../models/attendance.dart';
import '../models/employee.dart';

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
        COALESCE(a.day_total, 0) * e.daily_pay AS payable_this_month
      FROM employees e
      LEFT JOIN (
        SELECT employee_id,
          SUM(CASE WHEN status = 'present' THEN 1 ELSE 0 END) AS present_days,
          SUM(CASE WHEN status = 'half'    THEN 1 ELSE 0 END) AS half_days,
          SUM(CASE WHEN status = 'absent'  THEN 1 ELSE 0 END) AS absent_days,
          SUM(day_value)                                      AS day_total
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
        COALESCE(a.day_total, 0) * e.daily_pay AS payable_this_month
      FROM employees e
      LEFT JOIN (
        SELECT employee_id,
          SUM(CASE WHEN status = 'present' THEN 1 ELSE 0 END) AS present_days,
          SUM(CASE WHEN status = 'half'    THEN 1 ELSE 0 END) AS half_days,
          SUM(CASE WHEN status = 'absent'  THEN 1 ELSE 0 END) AS absent_days,
          SUM(day_value)                                      AS day_total
        FROM attendance
        WHERE substr(date, 1, 7) = ?
        GROUP BY employee_id
      ) a ON a.employee_id = e.id
      WHERE e.id = ?
    ''', [month, id]);
    return rows.isEmpty ? null : Employee.fromMap(rows.first);
  }

  Future<int> insert(Employee e) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now().toIso8601String();
    return db.insert('employees', {
      ...e.toMap(),
      'created_at': now,
      'updated_at': now,
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
    String? note,
  }) async {
    final db = await DatabaseHelper.database;
    final existing = await db.query(
      'attendance',
      where: 'employee_id = ? AND date = ?',
      whereArgs: [employeeId, date],
      limit: 1,
    );
    final values = {
      'employee_id': employeeId,
      'date': date,
      'status': status.db,
      'day_value': status.dayValue,
      'note': note,
    };
    if (existing.isEmpty) {
      await db.insert('attendance', values);
    } else {
      await db.update('attendance', values,
          where: 'id = ?', whereArgs: [existing.first['id']]);
    }
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
}
