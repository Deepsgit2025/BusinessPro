import 'package:intl/intl.dart';

/// Formatting helpers shared across screens.
class Formatters {
  Formatters._();

  static final _currency = NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: 2,
  );

  /// e.g. ₹1,23,456.00 (Indian grouping).
  static String currency(num value) => _currency.format(value);

  /// Bare number for editable amount fields: no symbol or grouping, trailing
  /// .00 dropped. e.g. 1000 → "1000", 1000.5 → "1000.5".
  static String plain(num value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();

  /// Quantity with optional unit short name, dropping trailing .00.
  /// e.g. 45 → "45", 2.5 → "2.5", with unit "pcs" → "45 pcs".
  static String qty(num value, [String? unitShort]) {
    final n = value == value.roundToDouble()
        ? value.toInt().toString()
        : value.toString();
    return unitShort == null || unitShort.isEmpty ? n : '$n $unitShort';
  }

  /// dd/MM/yyyy for a [DateTime] (used by date-range filters).
  static String dateShort(DateTime dt) => DateFormat('dd/MM/yyyy').format(dt);

  /// dd MMM yyyy, parsing either ISO or yyyy-MM-dd date strings.
  static String date(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final dt = DateTime.tryParse(raw);
    return dt == null ? raw : DateFormat('dd MMM yyyy').format(dt);
  }
}
