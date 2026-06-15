/// A recorded monthly salary payout for one employee. Maps to the
/// `salary_payments` table.
///
/// Written once when the user taps Save Payment on the salary screen; the
/// attendance counts and overtime are snapshotted at that moment so the
/// payslip stays correct even if attendance is later edited. `paymentMonth` is
/// a 'yyyy-MM' key.
class SalaryPayment {
  final int? id;
  final int businessId;
  final int employeeId;
  final String paymentMonth; // 'yyyy-MM'
  final double salaryEarned; // gross for the month
  final double cashPaid;
  final double advanceCredited; // recovered against outstanding advance
  final double remaining; // gross − cash − advanceCredited
  final int fullDays;
  final int halfDays;
  final int absentDays;
  final double overtimeHours;
  final double overtimeAmount;
  final String? notes;
  final String paymentDate; // ISO-8601 date

  const SalaryPayment({
    this.id,
    this.businessId = 1,
    required this.employeeId,
    required this.paymentMonth,
    required this.salaryEarned,
    this.cashPaid = 0,
    this.advanceCredited = 0,
    this.remaining = 0,
    this.fullDays = 0,
    this.halfDays = 0,
    this.absentDays = 0,
    this.overtimeHours = 0,
    this.overtimeAmount = 0,
    this.notes,
    required this.paymentDate,
  });

  factory SalaryPayment.fromMap(Map<String, dynamic> m) => SalaryPayment(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        employeeId: m['employee_id'] as int,
        paymentMonth: (m['payment_month'] as String?) ?? '',
        salaryEarned: (m['salary_earned'] as num?)?.toDouble() ?? 0,
        cashPaid: (m['cash_paid'] as num?)?.toDouble() ?? 0,
        advanceCredited: (m['advance_credited'] as num?)?.toDouble() ?? 0,
        remaining: (m['remaining'] as num?)?.toDouble() ?? 0,
        fullDays: (m['full_days'] as int?) ?? 0,
        halfDays: (m['half_days'] as int?) ?? 0,
        absentDays: (m['absent_days'] as int?) ?? 0,
        overtimeHours: (m['overtime_hours'] as num?)?.toDouble() ?? 0,
        overtimeAmount: (m['overtime_amount'] as num?)?.toDouble() ?? 0,
        notes: m['notes'] as String?,
        paymentDate: (m['payment_date'] as String?) ?? '',
      );

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'business_id': businessId,
        'employee_id': employeeId,
        'payment_month': paymentMonth,
        'salary_earned': salaryEarned,
        'cash_paid': cashPaid,
        'advance_credited': advanceCredited,
        'remaining': remaining,
        'full_days': fullDays,
        'half_days': halfDays,
        'absent_days': absentDays,
        'overtime_hours': overtimeHours,
        'overtime_amount': overtimeAmount,
        'notes': notes,
        'payment_date': paymentDate,
      };
}
