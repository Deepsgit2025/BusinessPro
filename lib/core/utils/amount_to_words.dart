/// Converts a rupee amount to words using the Indian numbering system
/// (thousand, lakh, crore) — not the Western million/billion grouping.
///
/// We hand-roll this rather than pull a package: most published converters use
/// the Western system and mis-render Indian amounts (e.g. 1,00,000 should read
/// "One Lakh", not "One Hundred Thousand"). Paise are rounded to two decimals.
///
/// Examples:
///   1250.50  → "One Thousand Two Hundred Fifty Rupees and Fifty Paise Only"
///   100000   → "One Lakh Rupees Only"
///   0        → "Zero Rupees Only"
class AmountToWords {
  AmountToWords._();

  static const _ones = [
    '', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine',
    'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen',
    'Seventeen', 'Eighteen', 'Nineteen',
  ];
  static const _tens = [
    '', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy',
    'Eighty', 'Ninety',
  ];

  /// Full sentence including the "Rupees … Paise Only" wrapper.
  static String rupees(num amount) {
    final negative = amount < 0;
    final abs = amount.abs();
    final rupees = abs.floor();
    // Round paise to avoid 0.1 + 0.2 style drift before truncating.
    final paise = ((abs - rupees) * 100).round();

    final parts = <String>[];
    if (rupees == 0) {
      parts.add('Zero Rupees');
    } else {
      parts.add('${_words(rupees)} Rupees');
    }
    if (paise > 0) {
      parts.add('and ${_words(paise)} Paise');
    }
    final body = '${parts.join(' ')} Only';
    return negative ? 'Minus $body' : body;
  }

  /// The number 0–999999999... spelled out under the Indian grouping, with no
  /// trailing "Rupees". Used internally; exposed for callers wanting bare words.
  static String _words(int number) {
    if (number == 0) return 'Zero';

    final buf = StringBuffer();

    // Crore (10,000,000) and above — recurse so very large values still group
    // correctly (e.g. "Two Hundred Crore").
    final crore = number ~/ 10000000;
    if (crore > 0) {
      buf.write('${_words(crore)} Crore ');
      number %= 10000000;
    }

    final lakh = number ~/ 100000;
    if (lakh > 0) {
      buf.write('${_twoDigits(lakh)} Lakh ');
      number %= 100000;
    }

    final thousand = number ~/ 1000;
    if (thousand > 0) {
      buf.write('${_twoDigits(thousand)} Thousand ');
      number %= 1000;
    }

    final hundred = number ~/ 100;
    if (hundred > 0) {
      buf.write('${_ones[hundred]} Hundred ');
      number %= 100;
    }

    if (number > 0) {
      buf.write(_twoDigits(number));
    }

    return buf.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  /// Spells a value 0–99.
  static String _twoDigits(int n) {
    if (n < 20) return _ones[n];
    final t = _tens[n ~/ 10];
    final o = _ones[n % 10];
    return o.isEmpty ? t : '$t $o';
  }
}
