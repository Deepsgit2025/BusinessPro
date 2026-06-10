import 'package:flutter_test/flutter_test.dart';

import 'package:business_pro/services/ocr/bill_parser.dart';

void main() {
  const parser = BillParser();

  group('GSTIN', () {
    test('extracts a valid 15-char GSTIN', () {
      final r = parser.parse('GSTIN: 27AABCS1429B1ZB\nrest of bill');
      expect(r.supplierGstin, '27AABCS1429B1ZB');
    });

    test('is null when no GSTIN present', () {
      final r = parser.parse('Sharma Traders\nTotal 100');
      expect(r.supplierGstin, isNull);
    });
  });

  group('date', () {
    test('parses DD/MM/YYYY', () {
      final r = parser.parse('Invoice Date: 15/06/2025');
      expect(r.billDate, DateTime(2025, 6, 15));
    });

    test('parses DD-MM-YY with 2-digit year', () {
      final r = parser.parse('Date 09-03-24');
      expect(r.billDate, DateTime(2024, 3, 9));
    });

    test('parses DD Mon YYYY', () {
      final r = parser.parse('Bill dated 15 Jun 2025');
      expect(r.billDate, DateTime(2025, 6, 15));
    });

    test('rejects an impossible month', () {
      final r = parser.parse('ref 45/99/2025');
      expect(r.billDate, isNull);
    });
  });

  group('bill number', () {
    test('extracts an invoice number', () {
      final r = parser.parse('Invoice No: INV-2025-441');
      expect(r.billNumber, 'INV-2025-441');
    });

    test('does not treat a bare day as a bill number', () {
      final r = parser.parse('No. 5');
      expect(r.billNumber, isNull);
    });
  });

  group('amounts', () {
    test('extracts grand total taking the largest on the line', () {
      final r = parser.parse('Grand Total  ₹ 1,416.00');
      expect(r.totalAmount, 1416.00);
    });

    test('sums CGST + SGST into tax amount', () {
      final r = parser.parse('CGST 9% 108.00\nSGST 9% 108.00');
      expect(r.taxAmount, 216.00);
    });

    test('extracts taxable subtotal', () {
      final r = parser.parse('Taxable Amount 1,200.00');
      expect(r.subtotal, 1200.00);
    });
  });

  group('supplier name', () {
    test('takes the first non-label line as the business name', () {
      final r = parser.parse(
          'Sharma Traders\nGSTIN 27AABCS1429B1ZB\nInvoice No 5');
      expect(r.supplierName, 'Sharma Traders');
    });
  });

  group('line items', () {
    test('parses a name qty rate amount row', () {
      final r = parser.parse('Biscuit Packet 50 10.00 500.00');
      expect(r.lineItems, hasLength(1));
      final item = r.lineItems.first;
      expect(item.itemName, 'Biscuit Packet');
      expect(item.quantity, 50);
      expect(item.unitPrice, 10.00);
      expect(item.totalPrice, 500.00);
    });

    test('skips total / tax rows', () {
      final r = parser.parse('Total 3 100.00 300.00');
      expect(r.lineItems, isEmpty);
    });
  });

  test('empty input yields an empty result without throwing', () {
    final r = parser.parse('');
    expect(r.isEmpty, isTrue);
    expect(r.rawText, '');
  });

  group('amount OCR noise', () {
    test('reads ₹ misread as a leading 7', () {
      // "₹46,666.67" often OCRs as "746,666.67".
      final r = parser.parse('Taxable Amount\n746,666.67');
      expect(r.subtotal, 46666.67);
    });

    test('reads a decimal point misread as a comma', () {
      // "49,000.00" can OCR as "49,000,00".
      final r = parser.parse('Total\n49,000,00');
      expect(r.totalAmount, 49000.00);
    });
  });

  group('table layout (label and value on separate lines)', () {
    // Mirrors a real screenshot of a printed GST invoice, where ML Kit emits
    // each label and its value on different lines, with status-bar junk mixed in.
    const raw = '''5:28 &
Bill To
AMBIKA AGROTECH
GSTIN: 23ALVPG8391E1ZB
Sale
PDF reader
Invoice No.
Invoice314
Place of Supply
08-Rajasthan
Sub Total
Taxable Amount
46,666.67
GST
2,333.33 (5.0%)
Total Tax Amount
Date
05-05-2026
Total
49,000.00
Received
49,000.00''';

    final r = parser.parse(raw);

    test('extracts the business name, skipping status-bar junk', () {
      expect(r.supplierName, 'AMBIKA AGROTECH');
    });
    test('extracts the GSTIN', () {
      expect(r.supplierGstin, '23ALVPG8391E1ZB');
    });
    test('extracts the invoice number from the next line', () {
      expect(r.billNumber, 'Invoice314');
    });
    test('extracts the date from the next line', () {
      expect(r.billDate, DateTime(2026, 5, 5));
    });
    test('extracts the subtotal', () {
      expect(r.subtotal, 46666.67);
    });
    test('extracts the tax amount', () {
      expect(r.taxAmount, 2333.33);
    });
    test('extracts the grand total as the largest money figure', () {
      expect(r.totalAmount, 49000.00);
    });
  });

  group('multi-item column-block layout', () {
    // A real photographed bill where OCR reads the item table column-by-column:
    // names, rates and amounts each arrive as a vertical block, the qty column
    // is partially dropped, and amounts carry OCR noise (₹→F/T, trailing 0→o,
    // an inflated "75,320.00" for "₹5,320.00").
    const raw = '''Golden Kirana
Chambal Naka
GSTIN: 1234567
Bill To
Guruji Narsingha
Item
honey gold
jadugar peti
wheel peti
Amount in words: Five Thousand Rupees Only
Bank Details
A/C No: 123456789
Qty
2
3
Subtotal
Total
Paid
Rate
F500.00
F400.00
T600.00
TAX INVOICE
No: INV-0009
Date: 10 Jun 2026
Amount
1,000.0o
1,200.00
1,200.00
75,320.00
T5,320.00
5,320.00
Scan to Pay
5,320.00''';

    final r = parser.parse(raw);

    test('extracts the bill number from a bare "No:" line', () {
      expect(r.billNumber, 'INV-0009');
    });

    test('reassembles item names, rates and amounts by column', () {
      expect(r.lineItems.map((i) => i.itemName).toList(),
          ['honey gold', 'jadugar peti', 'wheel peti']);
      expect(r.lineItems.map((i) => i.unitPrice).toList(), [500.0, 400.0, 600.0]);
      expect(r.lineItems.map((i) => i.totalPrice).toList(),
          [1000.0, 1200.0, 1200.0]);
    });

    test('derives a missing quantity from amount ÷ rate', () {
      // honey gold: 1000 / 500 = 2 (qty column only had two values for 3 rows).
      expect(r.lineItems.first.quantity, 2.0);
    });

    test('picks the repeated grand total, rejecting the inflated outlier', () {
      expect(r.totalAmount, 5320.00); // not 75,320.00
    });
  });
}
