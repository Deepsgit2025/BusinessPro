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

  test('signed overtime nets across the month (early-leave deducts)', () async {
    // Early-leave is logged as a negative overtime adjustment; at month-end the
    // signed hours net, so a -1.0h early-leave cancels part of a +2.0h overtime.
    final id = await repo.insert(
      const Employee(name: 'Nita', dailyPay: 500, overtimeRate: 100),
    );
    await repo.setAttendance(id, day(1), AttendanceStatus.present,
        overtimeHours: 2.0); // worked 2h overtime
    await repo.setAttendance(id, day(2), AttendanceStatus.present,
        overtimeHours: -1.0); // left 1h early

    final e = await repo.getById(id, month: month);
    expect(e!.presentDays, 2);
    // Net overtime = 2.0 + (-1.0) = 1.0 hours.
    expect(e.overtimeHours, closeTo(1.0, 0.001));
    // 2×500 + net 1.0×100 = 1000 + 100 = 1100.
    expect(e.payableThisMonth, closeTo(1100, 0.001));
  });

  test('a net-negative overtime month reduces gross below day pay', () async {
    final id = await repo.insert(
      const Employee(name: 'Omar', dailyPay: 500, overtimeRate: 100),
    );
    // One full day, but 1.5h early-leave and no overtime → net -1.5h.
    await repo.setAttendance(id, day(1), AttendanceStatus.present,
        overtimeHours: -1.5);

    final e = await repo.getById(id, month: month);
    expect(e!.overtimeHours, closeTo(-1.5, 0.001));
    // 1×500 + (-1.5)×100 = 500 - 150 = 350.
    expect(e.payableThisMonth, closeTo(350, 0.001));
  });

  test('salary slip PDF renders with a negative (early-leave) overtime',
      () async {
    final e = const Employee(
        id: 98, name: 'Nita', dailyPay: 500, overtimeRate: 100);
    final payment = SalaryPayment(
      employeeId: 98,
      paymentMonth: month,
      salaryEarned: 850,
      cashPaid: 850,
      advanceCredited: 0,
      remaining: 0,
      fullDays: 2,
      halfDays: 0,
      absentDays: 0,
      overtimeHours: -1.5, // net early-leave
      overtimeAmount: -150,
      paymentDate: day(28),
    );
    final bytes = await SalarySlipPdfService.build(
      employee: e,
      payment: payment,
    );
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
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
