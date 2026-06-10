import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:business_pro/features/items/models/item.dart';
import 'package:business_pro/features/parties/models/party.dart';

/// Verifies the Phase 2 model ↔ map round-trips and the derived getters that
/// the UI relies on (balance direction, low-stock flag, opening-stock seeding).
///
/// These exercise pure model logic plus a thin SQLite layer using an in-memory
/// database, so they run without the full app DB / business seed.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Party model', () {
    test('netBalance is positive (To Collect) for a debit opening balance', () {
      const p = Party(
        name: 'Acme',
        openingBalance: 500,
        openingBalanceType: 'debit',
      );
      expect(p.netBalance, 500);
    });

    test('netBalance is negative (To Pay) for a credit opening balance', () {
      const p = Party(
        name: 'Supplier Co',
        partyType: 'supplier',
        openingBalance: 300,
        openingBalanceType: 'credit',
      );
      expect(p.netBalance, -300);
    });

    test('toMap / fromMap round-trip preserves fields', () {
      const original = Party(
        name: 'Round Trip',
        partyType: 'both',
        phone: '9999999999',
        gstin: '22AAAAA0000A1Z5',
        creditLimit: 1000,
        creditDays: 30,
      );
      final restored = Party.fromMap({...original.toMap(), 'id': 1});
      expect(restored.name, 'Round Trip');
      expect(restored.partyType, 'both');
      expect(restored.isCustomer, isTrue);
      expect(restored.isSupplier, isTrue);
      expect(restored.creditLimit, 1000);
      expect(restored.creditDays, 30);
    });
  });

  group('Item model', () {
    test('low stock flag trips when current < min', () {
      const low = Item(name: 'Widget', currentStock: 3, minStockLevel: 10);
      const ok = Item(name: 'Widget', currentStock: 20, minStockLevel: 10);
      expect(low.isLowStock, isTrue);
      expect(ok.isLowStock, isFalse);
    });

    test('services never flag low stock', () {
      const service = Item(
        name: 'Consulting',
        itemType: 'service',
        currentStock: 0,
        minStockLevel: 5,
      );
      expect(service.isLowStock, isFalse);
    });

    test('stock value is current stock × purchase price', () {
      const it = Item(name: 'Bolt', currentStock: 10, purchasePrice: 2.5);
      expect(it.stockValue, 25);
    });
  });

  group('Items table — opening stock seeds current stock', () {
    test('inserting with opening_stock sets current_stock to match', () async {
      final db = await openDatabase(inMemoryDatabasePath, version: 1,
          onCreate: (db, _) async {
        await db.execute('''
          CREATE TABLE items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            business_id INTEGER, category_id INTEGER, unit_id INTEGER,
            tax_rate_id INTEGER, name TEXT, description TEXT, sku TEXT,
            barcode TEXT, hsn_code TEXT, item_type TEXT,
            sale_price REAL DEFAULT 0, purchase_price REAL DEFAULT 0,
            mrp REAL DEFAULT 0, opening_stock REAL DEFAULT 0,
            current_stock REAL DEFAULT 0, min_stock_level REAL DEFAULT 0,
            tax_inclusive INTEGER DEFAULT 0, is_active INTEGER DEFAULT 1
          )
        ''');
      });

      // Mirror ItemRepository.insert: current_stock seeded from opening_stock.
      const item = Item(name: 'Seeded', openingStock: 42);
      await db.insert('items', {
        ...item.toMap(),
        'current_stock': item.openingStock,
      });

      final rows = await db.query('items');
      expect(rows.single['current_stock'], 42.0);
      expect(rows.single['opening_stock'], 42.0);
      await db.close();
    });
  });
}
