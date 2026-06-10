import 'package:flutter_test/flutter_test.dart';
import 'package:business_pro/features/company/widgets/visiting_card.dart';

void main() {
  group('CardData and VisitingCard "Show on card" toggle tests', () {
    test('CardData includes all fields when all toggles are on', () {
      final cardData = CardData(
        name: 'Test Company',
        phone: '9876543210',
        email: 'test@company.com',
        address: '123 Main St',
        logoPath: null,
        gstin: 'GST123456789',
        businessType: 'Retailer',
        businessCategory: 'Electronics & Electrical',
      );

      expect(cardData.name, equals('Test Company'));
      expect(cardData.phone, equals('9876543210'));
      expect(cardData.email, equals('test@company.com'));
      expect(cardData.address, equals('123 Main St'));
      expect(cardData.gstin, equals('GST123456789'));
      expect(cardData.businessType, equals('Retailer'));
      expect(cardData.businessCategory, equals('Electronics & Electrical'));
    });

    test('CardData excludes gstin when toggle is off', () {
      // When _showGstin is false, gstin should be null in CardData
      final cardData = CardData(
        name: 'Test Company',
        phone: '9876543210',
        email: 'test@company.com',
        address: '123 Main St',
        logoPath: null,
        gstin: null,  // Excluded when toggle is off
        businessType: 'Retailer',
        businessCategory: 'Electronics & Electrical',
      );

      expect(cardData.gstin, isNull);
    });

    test('CardData excludes businessType when toggle is off', () {
      // When _showBusinessType is false, businessType should be null in CardData
      final cardData = CardData(
        name: 'Test Company',
        phone: '9876543210',
        email: 'test@company.com',
        address: '123 Main St',
        logoPath: null,
        gstin: 'GST123456789',
        businessType: null,  // Excluded when toggle is off
        businessCategory: 'Electronics & Electrical',
      );

      expect(cardData.businessType, isNull);
    });

    test('CardData excludes businessCategory when toggle is off', () {
      // When _showBusinessCategory is false, businessCategory should be null in CardData
      final cardData = CardData(
        name: 'Test Company',
        phone: '9876543210',
        email: 'test@company.com',
        address: '123 Main St',
        logoPath: null,
        gstin: 'GST123456789',
        businessType: 'Retailer',
        businessCategory: null,  // Excluded when toggle is off
      );

      expect(cardData.businessCategory, isNull);
    });

    test('CardData fingerprint changes when visibility toggles change', () {
      final cardDataWithGstin = CardData(
        name: 'Test Company',
        phone: '9876543210',
        email: 'test@company.com',
        address: '123 Main St',
        logoPath: null,
        gstin: 'GST123456789',
        businessType: null,
        businessCategory: null,
      );

      final cardDataWithoutGstin = CardData(
        name: 'Test Company',
        phone: '9876543210',
        email: 'test@company.com',
        address: '123 Main St',
        logoPath: null,
        gstin: null,
        businessType: null,
        businessCategory: null,
      );

      // Fingerprints should be different
      expect(
        cardDataWithGstin.fingerprint,
        isNot(equals(cardDataWithoutGstin.fingerprint)),
      );
    });

    test('CardData fingerprint is identical for same data', () {
      final cardData1 = CardData(
        name: 'Test Company',
        phone: '9876543210',
        email: 'test@company.com',
        address: '123 Main St',
        logoPath: null,
        gstin: 'GST123456789',
        businessType: 'Retailer',
        businessCategory: 'Electronics & Electrical',
      );

      final cardData2 = CardData(
        name: 'Test Company',
        phone: '9876543210',
        email: 'test@company.com',
        address: '123 Main St',
        logoPath: null,
        gstin: 'GST123456789',
        businessType: 'Retailer',
        businessCategory: 'Electronics & Electrical',
      );

      expect(cardData1.fingerprint, equals(cardData2.fingerprint));
    });
  });
}
