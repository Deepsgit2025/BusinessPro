/// One employee's attendance for a single day. Maps to the `attendance` table.
///
/// A day is either logged or not; at most one row exists per employee per date.
/// [dayValue] snapshots the pay weight at log time (1.0 present, 0.5 half,
/// 0.0 absent) so changing the half-day rule later never rewrites history.
enum AttendanceStatus {
  present,
  half,
  absent;

  String get db => name; // 'present' | 'half' | 'absent'

  double get dayValue => switch (this) {
        AttendanceStatus.present => 1.0,
        AttendanceStatus.half => 0.5,
        AttendanceStatus.absent => 0.0,
      };

  String get label => switch (this) {
        AttendanceStatus.present => 'Present',
        AttendanceStatus.half => 'Half day',
        AttendanceStatus.absent => 'Absent',
      };

  static AttendanceStatus fromDb(String? s) => switch (s) {
        'half' => AttendanceStatus.half,
        'absent' => AttendanceStatus.absent,
        _ => AttendanceStatus.present,
      };
}

class Attendance {
  final int? id;
  final int employeeId;
  final String date; // ISO-8601 date (yyyy-MM-dd)
  final AttendanceStatus status;
  final double dayValue;
  final double overtimeHours; // overtime worked on this day (rides on the row)
  final String? note;

  const Attendance({
    this.id,
    required this.employeeId,
    required this.date,
    required this.status,
    required this.dayValue,
    this.overtimeHours = 0,
    this.note,
  });

  /// True when the day carries logged overtime, regardless of present/half.
  bool get hasOvertime => overtimeHours > 0;

  factory Attendance.fromMap(Map<String, dynamic> m) => Attendance(
        id: m['id'] as int?,
        employeeId: m['employee_id'] as int,
        date: m['date'] as String,
        status: AttendanceStatus.fromDb(m['status'] as String?),
        dayValue: (m['day_value'] as num?)?.toDouble() ?? 0,
        overtimeHours: (m['overtime_hours'] as num?)?.toDouble() ?? 0,
        note: m['note'] as String?,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'employee_id': employeeId,
        'date': date,
        'status': status.db,
        'day_value': dayValue,
        'overtime_hours': overtimeHours,
        'note': note,
      };
}
