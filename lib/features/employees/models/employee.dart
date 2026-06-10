/// An employee paid a fixed wage per full day worked. Maps to the `employees`
/// table.
///
/// The list query joins in the current month's attendance roll-up; those
/// read-only view fields ([presentDays], [halfDays], [absentDays],
/// [payableThisMonth]) are not written back by [toMap].
class Employee {
  final int? id;
  final int businessId;
  final String name;
  final String? phone;
  final String? role;
  final double dailyPay;
  final String? joinDate; // ISO-8601 date
  final String? notes;
  final bool isActive;

  // Joined view data for the current month (not persisted on the employees row).
  final int presentDays;
  final int halfDays;
  final int absentDays;
  final double payableThisMonth;

  const Employee({
    this.id,
    this.businessId = 1,
    required this.name,
    this.phone,
    this.role,
    this.dailyPay = 0,
    this.joinDate,
    this.notes,
    this.isActive = true,
    this.presentDays = 0,
    this.halfDays = 0,
    this.absentDays = 0,
    this.payableThisMonth = 0,
  });

  /// Days that count toward pay this month (full + half), for the subtitle.
  double get paidDayCount => presentDays + halfDays * 0.5;

  factory Employee.fromMap(Map<String, dynamic> m) => Employee(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        name: (m['name'] as String?) ?? '',
        phone: m['phone'] as String?,
        role: m['role'] as String?,
        dailyPay: (m['daily_pay'] as num?)?.toDouble() ?? 0,
        joinDate: m['join_date'] as String?,
        notes: m['notes'] as String?,
        isActive: (m['is_active'] as int?) != 0,
        presentDays: (m['present_days'] as int?) ?? 0,
        halfDays: (m['half_days'] as int?) ?? 0,
        absentDays: (m['absent_days'] as int?) ?? 0,
        payableThisMonth: (m['payable_this_month'] as num?)?.toDouble() ?? 0,
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId,
        'name': name,
        'phone': phone,
        'role': role,
        'daily_pay': dailyPay,
        'join_date': joinDate,
        'notes': notes,
        'is_active': isActive ? 1 : 0,
      };

  Employee copyWith({
    String? name,
    String? phone,
    String? role,
    double? dailyPay,
    String? joinDate,
    String? notes,
    bool? isActive,
  }) =>
      Employee(
        id: id,
        businessId: businessId,
        name: name ?? this.name,
        phone: phone ?? this.phone,
        role: role ?? this.role,
        dailyPay: dailyPay ?? this.dailyPay,
        joinDate: joinDate ?? this.joinDate,
        notes: notes ?? this.notes,
        isActive: isActive ?? this.isActive,
        presentDays: presentDays,
        halfDays: halfDays,
        absentDays: absentDays,
        payableThisMonth: payableThisMonth,
      );
}
