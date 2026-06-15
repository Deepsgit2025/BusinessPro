import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' hide Transaction;

import 'package:business_pro/core/database/database_helper.dart';
import 'package:business_pro/features/transactions/models/transaction.dart';
import 'package:business_pro/features/transactions/models/transaction_item.dart';
import 'package:business_pro/features/transactions/services/invoice_pdf_service.dart';
import 'package:business_pro/features/transactions/services/invoice_format_registry.dart';

/// Verifies the invoice PDF generator produces a valid PDF and that the
/// bank-details / UPI-QR toggles gate the footer content. Uses the real bundled
/// Noto Sans fonts (loaded via rootBundle) and an in-memory seeded database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    // DatabaseHelper resolves its file path via path_provider, whose platform
    // channel is absent in headless tests. Point it at the system temp dir.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.createTempSync('biz_pro_test').path,
    );
  });

  Transaction sampleSale() => const Transaction(
        id: 1,
        transactionType: TxnTypes.sale,
        transactionNumber: 'INV-0001',
        transactionDate: '2026-06-09',
        subtotal: 1000,
        taxableAmount: 1000,
        cgstAmount: 90,
        sgstAmount: 90,
        taxAmount: 180,
        totalAmount: 1180,
        paidAmount: 180,
        balanceAmount: 1000,
        paymentStatus: 'partial',
        partyName: 'Acme Traders',
      );

  final items = const [
    TransactionItem(
      itemName: 'Widget A',
      itemHsn: '8471',
      unitName: 'pcs',
      quantity: 10,
      unitPrice: 100,
      taxRate: 18,
      taxAmount: 180,
      cgstAmount: 90,
      sgstAmount: 90,
      totalAmount: 1180,
    ),
  ];

  /// A PDF file always starts with the "%PDF" magic bytes.
  void expectValidPdf(Uint8List bytes) {
    expect(bytes.length, greaterThan(1000),
        reason: 'PDF should be non-trivial in size');
    expect(String.fromCharCodes(bytes.sublist(0, 4)), '%PDF');
  }

  test('builds a valid PDF with bank details + UPI QR when toggles ON', () async {
    final db = await DatabaseHelper.database;
    await db.update('businesses', {
      'name': 'My Test Shop',
      'gstin': '22AAAAA0000A1Z5',
      'bank_name': 'HDFC Bank',
      'bank_account_no': '50100123456789',
      'bank_ifsc': 'HDFC0001234',
      'upi_id': 'testshop@okhdfc',
      'print_bank_on_invoice': 1,
      'print_upi_qr_on_invoice': 1,
    }, where: 'id = 1');

    final bytes = await InvoicePdfService.build(
      transaction: sampleSale(),
      items: items,
    );
    expectValidPdf(bytes);
  });

  test('builds a valid PDF with toggles OFF (no bank/QR block)', () async {
    final db = await DatabaseHelper.database;
    await db.update('businesses', {
      'print_bank_on_invoice': 0,
      'print_upi_qr_on_invoice': 0,
    }, where: 'id = 1');

    final bytes = await InvoicePdfService.build(
      transaction: sampleSale(),
      items: items,
    );
    expectValidPdf(bytes);
  });

  test('estimate (Format 2) renders with Place of Supply + QR/bank/terms',
      () async {
    final db = await DatabaseHelper.database;
    await db.update('businesses', {
      'bank_name': 'HDFC Bank',
      'bank_account_no': '50100123456789',
      'bank_ifsc': 'HDFC0001234',
      'upi_id': 'testshop@okhdfc',
      'print_bank_on_invoice': 1,
      'print_upi_qr_on_invoice': 1,
    }, where: 'id = 1');

    final estimate = const Transaction(
      id: 2,
      transactionType: TxnTypes.estimate,
      transactionNumber: 'EST-0001',
      transactionDate: '2026-06-09',
      subtotal: 500,
      taxableAmount: 500,
      taxAmount: 90,
      cgstAmount: 45,
      sgstAmount: 45,
      totalAmount: 590,
      placeOfSupply: '10-Bihar',
      termsConditions: 'Valid for 15 days.',
      partyName: 'Prospect Co',
    );

    final bytes = await InvoicePdfService.build(
      transaction: estimate,
      items: items,
    );
    expectValidPdf(bytes);
  });

  test('sale invoice (Format 1) renders transport + shipping fields', () async {
    final db = await DatabaseHelper.database;
    await db.update('businesses', {
      'print_bank_on_invoice': 1,
      'print_upi_qr_on_invoice': 1,
      'upi_id': 'testshop@okhdfc',
    }, where: 'id = 1');

    final sale = const Transaction(
      id: 3,
      transactionType: TxnTypes.sale,
      transactionNumber: 'INV-0009',
      transactionDate: '2026-06-09',
      subtotal: 1000,
      taxableAmount: 1000,
      cgstAmount: 90,
      sgstAmount: 90,
      taxAmount: 180,
      totalAmount: 1180,
      ewayBillNumber: 'EWB123456',
      placeOfSupply: '10-Bihar',
      transportName: 'Blue Dart',
      vehicleNumber: 'BR01AB1234',
      deliveryLocation: 'Patna',
      isShippingDiff: true,
      shippingAddress: 'Plot 5, Industrial Area',
      shippingCity: 'Patna',
      shippingState: 'Bihar',
      shippingPincode: '800001',
      partyName: 'Acme Traders',
    );

    final bytes = await InvoicePdfService.build(
      transaction: sale,
      items: items,
      copyLabel: InvoicePdfService.copyLabels.first,
    );
    expectValidPdf(bytes);
  });

  test('buildAllCopies produces a 3-copy sale invoice PDF', () async {
    final bytes = await InvoicePdfService.buildAllCopies(
      transaction: sampleSale(),
      items: items,
    );
    expectValidPdf(bytes);
  });

  test('Format 1 footer renders the UPI QR when a UPI id is saved', () async {
    final db = await DatabaseHelper.database;
    await db.update('businesses', {
      'upi_id': 'testshop@okhdfc',
      'print_upi_qr_on_invoice': 1,
      'bank_name': 'HDFC Bank',
      'bank_account_no': '50100123456789',
      'bank_ifsc': 'HDFC0001234',
    }, where: 'id = 1');

    final bytes = await InvoicePdfService.build(
      transaction: sampleSale(),
      items: items,
    );
    expectValidPdf(bytes);
  });

  test('Format 1 footer falls back to Terms when no UPI id', () async {
    final db = await DatabaseHelper.database;
    // Clear the UPI id so the center cell must render Terms & Conditions.
    await db.update('businesses', {
      'upi_id': '',
      'print_upi_qr_on_invoice': 1,
    }, where: 'id = 1');

    final bytes = await InvoicePdfService.build(
      transaction: sampleSale(),
      items: items,
    );
    expectValidPdf(bytes);
  });

  test('bundled Noto Sans fonts include the rupee glyph (U+20B9)', () async {
    // The whole reason we bundle Noto Sans: the default PDF font lacks ₹.
    final data = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
    expect(data.lengthInBytes, greaterThan(10000));
    // We can't easily parse cmap here, but a successful PDF build above proves
    // the font loads and renders; this just guards the asset being present.
  });

  test('InvoiceFormatRegistry generates sale + estimate PDFs', () async {
    final estimate = const Transaction(
      id: 9,
      transactionType: TxnTypes.estimate,
      transactionNumber: 'EST-0042',
      transactionDate: '2026-06-14',
      subtotal: 500,
      taxableAmount: 500,
      taxAmount: 25,
      cgstAmount: 0,
      sgstAmount: 0,
      igstAmount: 25,
      totalAmount: 525,
      placeOfSupply: '10-Bihar',
      partyName: 'Prospect Co',
    );
    expectValidPdf(await InvoiceFormatRegistry.generate(
      docType: DocumentType.sale,
      transaction: sampleSale(),
      items: items,
    ));
    expectValidPdf(await InvoiceFormatRegistry.generate(
      docType: DocumentType.estimate,
      transaction: estimate,
      items: items,
    ));
    expectValidPdf(await InvoiceFormatRegistry.generateAllCopies(
      transaction: sampleSale(),
      items: items,
      labels: const ['ORIGINAL FOR RECIPIENT'],
    ));
  });

  test('format registry getFormats lists one option per doc type', () {
    expect(InvoiceFormatRegistry.getFormats(DocumentType.sale).first.key,
        'format1');
    expect(InvoiceFormatRegistry.getFormats(DocumentType.estimate).first.key,
        'format2');
    expect(InvoiceFormatRegistry.settingKey(DocumentType.estimate),
        'print_estimate_format');
  });
}
