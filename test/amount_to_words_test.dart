import 'package:flutter_test/flutter_test.dart';

import 'package:business_pro/core/utils/amount_to_words.dart';

/// Guards the Indian-numbering rupee-to-words converter used on invoice PDFs.
/// The Western grouping (million/billion) is explicitly wrong here, so the
/// lakh/crore boundaries are the cases that matter most.
void main() {
  group('AmountToWords.rupees', () {
    test('zero', () {
      expect(AmountToWords.rupees(0), 'Zero Rupees Only');
    });

    test('rupees with paise', () {
      expect(
        AmountToWords.rupees(1250.50),
        'One Thousand Two Hundred Fifty Rupees and Fifty Paise Only',
      );
    });

    test('exact lakh uses Indian grouping (not "hundred thousand")', () {
      expect(AmountToWords.rupees(100000), 'One Lakh Rupees Only');
    });

    test('crore boundary', () {
      expect(AmountToWords.rupees(10000000), 'One Crore Rupees Only');
    });

    test('mixed lakh + thousand + hundred + tens', () {
      expect(
        AmountToWords.rupees(123456),
        'One Lakh Twenty Three Thousand Four Hundred Fifty Six Rupees Only',
      );
    });

    test('paise rounding to two decimals', () {
      // 99.999 rounds to 100 paise → carries? We truncate rupees then round the
      // fractional part, so 99.995 → 99 rupees and 100 paise is avoided by
      // rounding the paise field independently.
      expect(AmountToWords.rupees(5.05),
          'Five Rupees and Five Paise Only');
    });

    test('teen values', () {
      expect(AmountToWords.rupees(13), 'Thirteen Rupees Only');
      expect(AmountToWords.rupees(19), 'Nineteen Rupees Only');
    });

    test('negative amount', () {
      expect(AmountToWords.rupees(-50), 'Minus Fifty Rupees Only');
    });
  });
}
