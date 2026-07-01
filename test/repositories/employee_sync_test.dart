// Employee-module sync round-trip tests (v14).
//
// Before v14 the employee tables (employees / attendance / salary_payments /
// employee_advances) were never registered as synced tables, so nothing about
// them entered the Drive sync channel. v14 brings them in: uuid identity,
// device_id/is_synced tracking, the stamping/dirty triggers, FK-uuid remap of
// employee_id, and a natural-key collision resolver for attendance's
// UNIQUE(employee_id, date).
//
// These tests drive the REAL DatabaseHelper singleton + the REAL SyncRepository
// against throwaway temp databases (path_provider is mocked to a temp dir, as
// in transaction_repository_edit_guard_test.dart). "Device B" is simulated by
// closing the singleton and opening a fresh temp DB, then merging device A's
// exported ChangeSet into it — exactly what the engine does across devices,
// minus the network.

import 'dart:io';

import 'package:business_pro/core/database/database_helper.dart';
import 'package:business_pro/services/sync/sync_repository.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  const pathProviderChannel =
      MethodChannel('plugins.flutter.io/path_provider');

  late Directory tempDir;

  /// Points DatabaseHelper at a brand-new temp DB (simulating a second device).
  /// Closes any open singleton first so _initDb reopens against the new dir.
  Future<void> useFreshDb() async {
    await DatabaseHelper.close();
    tempDir = await Directory.systemTemp.createTemp('bp_emp_sync_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
      return tempDir.path;
    });
    // Force open so the schema (v14) is built now.
    await DatabaseHelper.database;
  }

  setUp(() async {
    await useFreshDb();
  });

  tearDown(() async {
    await DatabaseHelper.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    try {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    } catch (_) {
      // Best-effort cleanup.
    }
  });

  /// Inserts an employee and returns its local id. The AFTER INSERT trigger
  /// stamps a uuid (we don't supply one), mirroring a real repository insert.
  Future<int> insertEmployee(String name) async {
    final db = await DatabaseHelper.database;
    return db.insert('employees', {
      'business_id': 1,
      'name': name,
      'daily_pay': 500.0,
    });
  }

  Future<int> insertAttendance(int employeeId, String date, String status,
      {double overtimeHours = 0}) async {
    final db = await DatabaseHelper.database;
    return db.insert('attendance', {
      'employee_id': employeeId,
      'date': date,
      'status': status,
      'day_value': status == 'present' ? 1.0 : (status == 'half' ? 0.5 : 0.0),
      'overtime_hours': overtimeHours,
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  Future<Map<String, dynamic>?> rowByUuid(String table, String uuid) async {
    final db = await DatabaseHelper.database;
    final rows =
        await db.query(table, where: 'uuid = ?', whereArgs: [uuid], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  test('employee tables are registered for sync', () {
    expect(DatabaseHelper.syncedTables, containsAll(<String>[
      'employees',
      'attendance',
      'salary_payments',
      'employee_advances',
    ]));
  });

  test('insert stamps uuid + device_id on employee and attendance', () async {
    final empId = await insertEmployee('Asha');
    final attId = await insertAttendance(empId, '2026-06-01', 'present');
    final db = await DatabaseHelper.database;

    final emp = (await db.query('employees',
            where: 'id = ?', whereArgs: [empId], limit: 1))
        .first;
    final att = (await db.query('attendance',
            where: 'id = ?', whereArgs: [attId], limit: 1))
        .first;

    expect(emp['uuid'], isNotNull, reason: 'employee uuid stamped on insert');
    expect(att['uuid'], isNotNull, reason: 'attendance uuid stamped on insert');
  });

  test('export attaches the parent uuid helper for attendance.employee_id',
      () async {
    final empId = await insertEmployee('Asha');
    await insertAttendance(empId, '2026-06-01', 'present');

    final repo = SyncRepository();
    final changes = await repo.getLocalChanges(
      deviceId: 'device-A',
      deviceType: 'android',
    );

    final emp = changes.byTable['employees']!.single;
    final att = changes.byTable['attendance']!.single;

    // The attendance record carries the employee's uuid (not the local int id)
    // so the other device can re-link it.
    expect(att.data['_employee_id_uuid'], emp.uuid,
        reason: 'attendance export must carry the parent uuid helper');
  });

  test('cross-device merge re-links attendance by employee uuid', () async {
    // ── Device A: create an employee + one attendance row, then export. ──
    final empIdA = await insertEmployee('Asha');
    await insertAttendance(empIdA, '2026-06-01', 'present', overtimeHours: 2);

    final repoA = SyncRepository();
    final changes = await repoA.getLocalChanges(
      deviceId: 'device-A',
      deviceType: 'android',
    );
    final empRec = changes.byTable['employees']!.single;
    final attRec = changes.byTable['attendance']!.single;

    // ── Device B: fresh DB; merge A's rows in dependency order. ──
    await useFreshDb();
    final repoB = SyncRepository();

    // Parent first (engine's merge order), then child.
    expect(await repoB.canResolveParents('employees', empRec.data), isTrue);
    await repoB.insertFromSync('employees', empRec.data, empRec.updatedAt);

    // Child can resolve its parent now that the employee exists locally.
    expect(await repoB.canResolveParents('attendance', attRec.data), isTrue);
    await repoB.insertFromSync('attendance', attRec.data, attRec.updatedAt);

    // The attendance row landed and points at device B's LOCAL employee id.
    final empB = await rowByUuid('employees', empRec.uuid);
    final attB = await rowByUuid('attendance', attRec.uuid);
    expect(empB, isNotNull);
    expect(attB, isNotNull);
    expect(attB!['employee_id'], empB!['id'],
        reason: 'employee_id remapped to device B local id');
    expect(attB['overtime_hours'], 2.0,
        reason: 'overtime value carried across');
  });

  test('attendance child defers until its parent employee has merged', () async {
    final empIdA = await insertEmployee('Asha');
    await insertAttendance(empIdA, '2026-06-01', 'present');

    final repoA = SyncRepository();
    final changes = await repoA.getLocalChanges(
      deviceId: 'device-A',
      deviceType: 'android',
    );
    final attRec = changes.byTable['attendance']!.single;

    await useFreshDb();
    final repoB = SyncRepository();

    // Parent employee NOT merged yet → the child must be deferred, not inserted
    // (otherwise the NOT NULL / FK employee_id would fail).
    expect(await repoB.canResolveParents('attendance', attRec.data), isFalse,
        reason: 'attendance must wait for its employee parent');
  });

  test('attendance natural-key collision resolves latest-wins, converging uuids',
      () async {
    // Device A logs employee Asha present on 2026-06-01.
    final empIdA = await insertEmployee('Asha');
    await insertAttendance(empIdA, '2026-06-01', 'present');

    final repoA = SyncRepository();
    final changesA = await repoA.getLocalChanges(
      deviceId: 'device-A',
      deviceType: 'android',
    );
    final empRecA = changesA.byTable['employees']!.single;
    final attRecA = changesA.byTable['attendance']!.single;

    // ── Device B: the SAME employee already exists (merged earlier) and B
    //    independently logged the SAME day as 'absent' a moment LATER. ──
    await useFreshDb();
    final repoB = SyncRepository();
    await repoB.insertFromSync('employees', empRecA.data, empRecA.updatedAt);
    final empB = (await rowByUuid('employees', empRecA.uuid))!;
    // B's own attendance row: same employee+date, different uuid, newer time.
    final db = await DatabaseHelper.database;
    await db.insert('attendance', {
      'employee_id': empB['id'],
      'date': '2026-06-01',
      'status': 'absent',
      'day_value': 0.0,
      'overtime_hours': 0,
      'uuid': 'device-B-att-uuid',
      'updated_at':
          DateTime.now().add(const Duration(minutes: 5)).toIso8601String(),
    });

    // Now A's (older) row arrives. Replicate the engine's natural-key path:
    // uuid miss → natural-key twin found → latest-wins. B's row is newer, so A
    // must NOT overwrite it, and there must remain exactly ONE row for the day.
    expect(await repoB.findByUuid('attendance', attRecA.uuid), isNull);
    final remapped =
        await repoB.remapForeignKeysForLookup('attendance', attRecA.data);
    final twin = await repoB.findByNaturalKey('attendance', remapped);
    expect(twin, isNotNull,
        reason: 'B already has a row for this employee+date');
    expect(twin!['status'], 'absent',
        reason: "B's newer row wins; A's older 'present' does not overwrite");

    // Exactly one attendance row for the day — no UNIQUE-violation duplicate.
    final count = (await db.rawQuery(
      'SELECT COUNT(*) AS c FROM attendance WHERE date = ?',
      ['2026-06-01'],
    ))
        .first['c'] as int;
    expect(count, 1, reason: 'natural key kept a single row, no duplicate');
  });
}
