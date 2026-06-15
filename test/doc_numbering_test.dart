import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:business_pro/core/database/database_helper.dart';

/// Per-prefix document numbering (`counter_<type>_<PREFIX>`): peek must not
/// consume, consume must advance, and changing the prefix must start a fresh
/// sequence seeded from the legacy column counter so existing runs continue.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.createTempSync('numbering_test').path,
    );
  });

  test('peek does not consume; consume advances', () async {
    // Fresh seed: invoice_prefix INV, invoice_counter 1.
    await DatabaseHelper.updateBusiness(
        {'invoice_prefix': 'INV', 'invoice_counter': 1});

    final p1 = await DatabaseHelper.peekDocNumber('sale');
    final p2 = await DatabaseHelper.peekDocNumber('sale');
    expect(p1, endsWith('INV-0001'));
    expect(p2, equals(p1), reason: 'peek must be idempotent');

    final c1 = await DatabaseHelper.consumeDocNumber('sale');
    expect(c1, endsWith('INV-0001'));
    final p3 = await DatabaseHelper.peekDocNumber('sale');
    expect(p3, endsWith('INV-0002'), reason: 'consume advanced the sequence');
  });

  test('first use of a prefix seeds from the legacy counter', () async {
    // ACME is a never-before-seen prefix, so it seeds from invoice_counter.
    await DatabaseHelper.updateBusiness(
        {'invoice_prefix': 'ACME', 'invoice_counter': 50});
    expect(await DatabaseHelper.peekDocNumber('sale'), endsWith('ACME-0050'));
    await DatabaseHelper.consumeDocNumber('sale'); // ACME → 51
    expect(await DatabaseHelper.peekDocNumber('sale'), endsWith('ACME-0051'));
  });

  test('switching prefixes keeps each sequence independent', () async {
    // The key guarantee: numbers issued under one prefix never collide with
    // another prefix's, and switching back resumes a prefix's own sequence.
    await DatabaseHelper.updateBusiness({'invoice_prefix': 'SEPT'});
    final sept1 = await DatabaseHelper.consumeDocNumber('sale');
    expect(sept1, contains('SEPT-'));

    // Switching back to ACME resumes its own sequence at 51 (consumed to 51
    // in the previous test), independent of SEPT.
    await DatabaseHelper.updateBusiness({'invoice_prefix': 'ACME'});
    expect(await DatabaseHelper.peekDocNumber('sale'), endsWith('ACME-0051'));

    // And SEPT still has its own next value, unaffected by ACME.
    await DatabaseHelper.updateBusiness({'invoice_prefix': 'SEPT'});
    final septNext = await DatabaseHelper.peekDocNumber('sale');
    expect(septNext, contains('SEPT-'));
    expect(septNext, isNot(equals(sept1)),
        reason: 'SEPT advanced after its own consume, not reset by ACME');
  });

  test('sale and purchase counters are independent', () async {
    await DatabaseHelper.updateBusiness({
      'invoice_prefix': 'AINV',
      'invoice_counter': 5,
      'purchase_prefix': 'APUR',
      'purchase_counter': 9,
    });
    expect(await DatabaseHelper.peekDocNumber('sale'), endsWith('AINV-0005'));
    expect(
        await DatabaseHelper.peekDocNumber('purchase'), endsWith('APUR-0009'));
    await DatabaseHelper.consumeDocNumber('sale');
    // Purchase unaffected by a sale consume.
    expect(
        await DatabaseHelper.peekDocNumber('purchase'), endsWith('APUR-0009'));
  });

  test('monthly mode prefixes with the current month name', () async {
    final month = DatabaseHelper.monthlyPrefix();
    expect(month, isNotEmpty);
    // Turning on monthly mode makes the active prefix the month name.
    await DatabaseHelper.setSetting('prefix_mode_sale', 'monthly');
    expect(await DatabaseHelper.prefixFor('sale'), equals(month));
    expect(await DatabaseHelper.peekDocNumber('sale'), contains('$month-'));
    // Restore custom mode for any later assertions.
    await DatabaseHelper.setSetting('prefix_mode_sale', 'custom');
  });

  test('previewDocNumber peeks an arbitrary prefix; resetCounter restarts it',
      () async {
    // Preview a never-seen prefix → seeds from the legacy counter, no consume.
    await DatabaseHelper.updateBusiness({'invoice_counter': 7});
    final p = await DatabaseHelper.previewDocNumber('sale', 'ZZTOP');
    expect(p, endsWith('ZZTOP-0007'));
    // Peeking again is unchanged (preview never consumes).
    expect(await DatabaseHelper.previewDocNumber('sale', 'ZZTOP'),
        endsWith('ZZTOP-0007'));
    // Advance then reset.
    await DatabaseHelper.updateBusiness({'invoice_prefix': 'ZZTOP'});
    await DatabaseHelper.setSetting('prefix_mode_sale', 'custom');
    await DatabaseHelper.consumeDocNumber('sale'); // ZZTOP → 8
    await DatabaseHelper.resetCounter('sale', 'ZZTOP');
    expect(await DatabaseHelper.previewDocNumber('sale', 'ZZTOP'),
        endsWith('ZZTOP-0001'));
  });
}
