/// One row in an item's stock journey. Either a real transaction line
/// (purchase / sale / return) assembled by [InventoryRepository.getJourney],
/// or a synthetic opening-stock row built by the provider.
///
/// All quantities are expressed in the item's base unit. [signedBaseQty] is the
/// stock delta in base units: positive for inflows (purchase, sale return,
/// opening stock), negative for outflows (sale, purchase return).
class JourneyEntry {
  /// One of: 'purchase', 'sale', 'purchase_return', 'sale_return', 'opening'.
  final String type;
  final String? transactionNumber;
  final DateTime date;
  final String? partyName;

  /// Raw quantity in the transacted unit (e.g. 5 Tin). Zero for opening stock.
  final double quantity;
  final String? unitName;
  final double unitPrice;
  final double conversionFactor;

  const JourneyEntry({
    required this.type,
    required this.date,
    this.transactionNumber,
    this.partyName,
    this.quantity = 0,
    this.unitName,
    this.unitPrice = 0,
    this.conversionFactor = 1,
  });

  bool get isInflow =>
      type == 'purchase' || type == 'sale_return' || type == 'opening';

  /// Stock change in base units, signed by flow direction.
  double get signedBaseQty {
    final base = quantity * conversionFactor;
    return isInflow ? base : -base;
  }

  /// Human label for the type tag, e.g. "PURCHASE RETURN".
  String get label {
    switch (type) {
      case 'purchase':
        return 'PURCHASE';
      case 'purchase_return':
        return 'PURCHASE RETURN';
      case 'sale':
        return 'SALE';
      case 'sale_return':
        return 'SALE RETURN';
      case 'opening':
        return 'OPENING STOCK';
      default:
        return type.toUpperCase();
    }
  }

  factory JourneyEntry.fromMap(Map<String, dynamic> m) => JourneyEntry(
        type: (m['transaction_type'] as String?) ?? '',
        transactionNumber: m['transaction_number'] as String?,
        date: DateTime.tryParse((m['transaction_date'] as String?) ?? '') ??
            DateTime.now(),
        partyName: m['party_name'] as String?,
        quantity: (m['quantity'] as num?)?.toDouble() ?? 0,
        unitName: m['unit_name'] as String?,
        unitPrice: (m['unit_price'] as num?)?.toDouble() ?? 0,
        conversionFactor: (m['conversion_factor'] as num?)?.toDouble() ?? 1,
      );

  /// Synthetic opening-stock entry (not from the transactions table).
  factory JourneyEntry.opening({
    required double openingStock,
    required DateTime date,
  }) =>
      JourneyEntry(
        type: 'opening',
        date: date,
        quantity: openingStock,
        conversionFactor: 1,
      );
}
