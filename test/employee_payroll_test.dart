import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:business_pro/features/employees/models/attendance.dart';
import 'package:business_pro/features/employees/models/employee.dart';
import 'package:business_pro/features/employees/models/salary_payment.dart';
import 'package:business_pro/features/employees/repositories/employee_repository.dart';
import 'package:business_pro/features/employees/services/salary_slip_pdf_service.dart';

/// Exercises the v13 employee additions: overtime in the payroll roll-up,
/// the advance ledger (given / opening / recovered), salary payment recording,
/// and the salary-slip PDF render. Uses an in-memory seeded database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final repo = EmployeeRepository();
  late String month;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.createTempSync('emp_test').path,
    );
    final now = DateTime.now();
    month =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
  });

  String day(int d) =>
      '$month-${d.toString().padLeft(2, '0')}';

  test('opening advance creates an outstanding balance + ledger entry',
      () async {
    final id = await repo.insert(
      const Employee(name: 'Amin', dailyPay: 500, overtimeRate: 80),
      openingAdvance: 50000,
    );
    final e = await repo.getById(id, month: month);
    expect(e!.advanceOutstanding, 50000);

    final ledger = await repo.advancesFor(id);
    expect(ledger.length, 1);
    expect(ledger.first.amount, 50000);
  });

  test('overtime hours flow into the payroll roll-up', () async {
    final id = await repo.insert(
      const Employee(name: 'Ravi', dailyPay: 600, overtimeRate: 100),
    );
    // 2 full days + 1 half day + 2.5 overtime hours on day 1.
    await repo.setAttendance(id, day(1), AttendanceStatus.present);
    await repo.setAttendance(id, day(2), AttendanceStatus.present);
    await repo.setAttendance(id, day(3), AttendanceStatus.half);
    await repo.setOvertime(id, day(1), 2.5);

    final e = await repo.getById(id, month: month);
    expect(e!.presentDays, 2);
    expect(e.halfDays, 1);
    expect(e.overtimeHours, 2.5);
    // 2×600 + 0.5×600 + 2.5×100 = 1200 + 300 + 250 = 1750.
    expect(e.payableThisMonth, closeTo(1750, 0.001));
  });

  test('setOvertime does not clear an existing day status', () async {
    final id = await repo.insert(const Employee(name: 'Sita', dailyPay: 400));
    await repo.setAttendance(id, day(5), AttendanceStatus.half);
    await repo.setOvertime(id, day(5), 3);
    final att = await repo.attendanceForMonth(id, month);
    expect(att[day(5)]!.status, AttendanceStatus.half);
    expect(att[day(5)]!.overtimeHours, 3);
  });

  test('salary payment recovers advance and writes history', () async {
    final id = await repo.insert(
      const Employee(name: 'Geeta', dailyPay: 500, overtimeRate: 80),
      openingAdvance: 50000,
    );
    final payment = SalaryPayment(
      employeeId: id,
      paymentMonth: month,
      salaryEarned: 11900,
      cashPaid: 4000,
      advanceCredited: 10000,
      remaining: 0,
      fullDays: 22,
      halfDays: 2,
      absentDays: 2,
      overtimeHours: 5,
      overtimeAmount: 400,
      paymentDate: day(28),
    );
    await repo.recordSalaryPayment(payment);

    final e = await repo.getById(id, month: month);
    // Outstanding drops by the credited amount: 50000 − 10000.
    expect(e!.advanceOutstanding, 40000);

    final history = await repo.salaryHistory(id);
    expect(history.length, 1);
    expect(history.first.cashPaid, 4000);

    final forMonth = await repo.salaryForMonth(id, month);
    expect(forMonth, isNotNull);

    // The credited recovery is recorded in the ledger alongside the opening.
    final ledger = await repo.advancesFor(id);
    expect(ledger.length, 2);
  });

  test('salary slip PDF renders to valid bytes', () async {
    final e = const Employee(
        id: 99, name: 'Amin', phone: '9876543210', dailyPay: 500, overtimeRate: 80);
    final payment = SalaryPayment(
      employeeId: 99,
      paymentMonth: month,
      salaryEarned: 11900,
      cashPaid: 4000,
      advanceCredited: 10000,
      remaining: 0,
      fullDays: 22,
      halfDays: 2,
      absentDays: 2,
      overtimeHours: 5,
      overtimeAmount: 400,
      paymentDate: day(28),
    );
    final bytes = await SalarySlipPdfService.build(
      employee: e,
      payment: payment,
      openingAdvance: 50000,
    );
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
  });
}
