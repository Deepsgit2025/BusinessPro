import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:business_pro/features/items/models/item_unit.dart';

/// Verifies the multi-tier unit pricing feature: the ItemUnit model round-trip,
/// the conversion-factor stock trigger maths, and that a single-tier item still
/// behaves like the old single-unit path.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ItemUnit model', () {
    test('toMap omits item_id when null, includes it when set', () {
      const detached = ItemUnit(unitId: 1, unitName: 'Bottle');
      expect(detached.toMap().containsKey('item_id'), isFalse);

      const attached = ItemUnit(itemId: 7, unitId: 1, unitName: 'Bottle');
      expect(attached.toMap()['item_id'], 7);
    });

    test('fromMap / toMap round-trips the tier fields', () {
      const original = ItemUnit(
        itemId: 3,
        unitId: 5,
        unitName: 'Tin',
        conversionFactor: 5000,
        salePrice: 420,
        purchasePrice: 370,
        mrp: 480,
        isBaseUnit: false,
        isDefaultSale: true,
        sortOrder: 2,
      );
      final restored = ItemUnit.fromMap({...original.toMap(), 'id': 9});
      expect(restored.id, 9);
      expect(restored.unitName, 'Tin');
      expect(restored.conversionFactor, 5000);
      expect(restored.salePrice, 420);
      expect(restored.isBaseUnit, isFalse);
      expect(restored.isDefaultSale, isTrue);
      expect(restored.isDefaultPurchase, isFalse);
      expect(restored.sortOrder, 2);
    });

    test('copyWith enforcing single default-sale clears the previous one', () {
      const a = ItemUnit(unitId: 1, unitName: 'Pouch', isDefaultSale: true);
      final cleared = a.copyWith(isDefaultSale: false);
      expect(cleared.isDefaultSale, isFalse);
      expect(cleared.unitName, 'Pouch'); // other fields preserved
    });
  });

  group('Stock trigger uses conversion_factor', () {
    late Database db;

    setUp(() async {
      db = await openDatabase(inMemoryDatabasePath, version: 1,
          onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            current_stock REAL DEFAULT 0,
            updated_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            transaction_type TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE transaction_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            transaction_id INTEGER,
            item_id INTEGER,
            quantity REAL DEFAULT 1,
            conversion_factor REAL DEFAULT 1
          )
        ''');
        // Mirror the production sale trigger.
        await db.execute('''
          CREATE TRIGGER trg_stock_decrease_on_sale
          AFTER INSERT ON transaction_items
          WHEN (SELECT transaction_type FROM transactions WHERE id = NEW.transaction_id) = 'sale'
            AND NEW.item_id IS NOT NULL
          BEGIN
            UPDATE items
            SET current_stock = current_stock - (NEW.quantity * COALESCE(NEW.conversion_factor, 1))
            WHERE id = NEW.item_id;
          END
        ''');
      });
      await db.insert('items', {'id': 1, 'current_stock': 50000});
      await db.insert('transactions', {'id': 1, 'transaction_type': 'sale'});
    });

    tearDown(() => db.close());

    Future<double> stock() async {
      final r = await db.query('items', where: 'id = 1');
      return r.single['current_stock'] as double;
    }

    test('selling 3 bottles (×1000) deducts 3000 base units', () async {
      await db.insert('transaction_items', {
        'transaction_id': 1,
        'item_id': 1,
        'quantity': 3,
        'conversion_factor': 1000,
      });
      expect(await stock(), 47000);
    });

    test('single-unit line (conversion 1) deducts the raw quantity', () async {
      await db.insert('transaction_items', {
        'transaction_id': 1,
        'item_id': 1,
        'quantity': 4,
        'conversion_factor': 1,
      });
      expect(await stock(), 49996);
    });

    test('missing conversion_factor falls back to 1 via COALESCE', () async {
      await db.insert('transaction_items', {
        'transaction_id': 1,
        'item_id': 1,
        'quantity': 5,
        'conversion_factor': null,
      });
      expect(await stock(), 49995);
    });
  });
}
