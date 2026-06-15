/// One advance ledger entry for an employee. Maps to the `employee_advances`
/// table.
///
/// `type` is 'given' (money advanced to the employee, increases outstanding) or
/// 'credited' (recovered from a salary payment, decreases outstanding). The
/// running totals live on the employees row (advance_given / advance_paid); this
/// table is the audit trail of how they got there.
enum AdvanceType {
  given,
  credited;

  String get db => name;

  static AdvanceType fromDb(String? s) =>
      s == 'credited' ? AdvanceType.credited : AdvanceType.given;
}

class EmployeeAdvance {
  final int? id;
  final int businessId;
  final int employeeId;
  final double amount;
  final AdvanceType type;
  final String? notes;
  final String advanceDate; // ISO-8601 date

  const EmployeeAdvance({
    this.id,
    this.businessId = 1,
    required this.employeeId,
    required this.amount,
    required this.type,
    this.notes,
    required this.advanceDate,
  });

  factory EmployeeAdvance.fromMap(Map<String, dynamic> m) => EmployeeAdvance(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        employeeId: m['employee_id'] as int,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        type: AdvanceType.fromDb(m['type'] as String?),
        notes: m['notes'] as String?,
        advanceDate: (m['advance_date'] as String?) ?? '',
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId,
        'employee_id': employeeId,
        'amount': amount,
        'type': type.db,
        'notes': notes,
        'advance_date': advanceDate,
      };
}
