/// A single line item on a transaction. Maps to `transaction_items`.
///
/// All display data is snapshotted at save time ([itemName], [unitName],
/// [taxRate], [conversionFactor]) so historical invoices never read the live
/// item master. Stock triggers multiply [quantity] × [conversionFactor].
class TransactionItem {
  final int? id;
  final int? transactionId;
  final int? itemId;
  final int? itemUnitId;
  final String itemName;
  final String? itemHsn;
  final String? unitName;
  final double quantity;
  final double conversionFactor;
  final double unitPrice;
  final double mrp;
  final String discountType; // 'none' | 'percent' | 'flat'
  final double discountValue;
  final double discountAmount;
  final double taxableAmount;
  final int? taxRateId;
  final double taxRate;
  final double taxAmount;
  final double cgstAmount;
  final double sgstAmount;
  final double igstAmount;
  final bool taxInclusive;
  final double totalAmount;
  final int sortOrder;
  final String? notes;

  const TransactionItem({
    this.id,
    this.transactionId,
    this.itemId,
    this.itemUnitId,
    required this.itemName,
    this.itemHsn,
    this.unitName,
    this.quantity = 1,
    this.conversionFactor = 1,
    this.unitPrice = 0,
    this.mrp = 0,
    this.discountType = 'none',
    this.discountValue = 0,
    this.discountAmount = 0,
    this.taxableAmount = 0,
    this.taxRateId,
    this.taxRate = 0,
    this.taxAmount = 0,
    this.cgstAmount = 0,
    this.sgstAmount = 0,
    this.igstAmount = 0,
    this.taxInclusive = false,
    this.totalAmount = 0,
    this.sortOrder = 0,
    this.notes,
  });

  factory TransactionItem.fromMap(Map<String, dynamic> m) => TransactionItem(
        id: m['id'] as int?,
        transactionId: m['transaction_id'] as int?,
        itemId: m['item_id'] as int?,
        itemUnitId: m['item_unit_id'] as int?,
        itemName: (m['item_name'] as String?) ?? '',
        itemHsn: m['item_hsn'] as String?,
        unitName: m['unit_name'] as String?,
        quantity: (m['quantity'] as num?)?.toDouble() ?? 1,
        conversionFactor: (m['conversion_factor'] as num?)?.toDouble() ?? 1,
        unitPrice: (m['unit_price'] as num?)?.toDouble() ?? 0,
        mrp: (m['mrp'] as num?)?.toDouble() ?? 0,
        discountType: (m['discount_type'] as String?) ?? 'none',
        discountValue: (m['discount_value'] as num?)?.toDouble() ?? 0,
        discountAmount: (m['discount_amount'] as num?)?.toDouble() ?? 0,
        taxableAmount: (m['taxable_amount'] as num?)?.toDouble() ?? 0,
        taxRateId: m['tax_rate_id'] as int?,
        taxRate: (m['tax_rate'] as num?)?.toDouble() ?? 0,
        taxAmount: (m['tax_amount'] as num?)?.toDouble() ?? 0,
        cgstAmount: (m['cgst_amount'] as num?)?.toDouble() ?? 0,
        sgstAmount: (m['sgst_amount'] as num?)?.toDouble() ?? 0,
        igstAmount: (m['igst_amount'] as num?)?.toDouble() ?? 0,
        taxInclusive: ((m['tax_inclusive'] as int?) ?? 0) == 1,
        totalAmount: (m['total_amount'] as num?)?.toDouble() ?? 0,
        sortOrder: (m['sort_order'] as int?) ?? 0,
        notes: m['notes'] as String?,
      );

  /// Column map for insert. [transactionId] is attached by the repository.
  Map<String, dynamic> toMap() => {
        if (transactionId != null) 'transaction_id': transactionId,
        'item_id': itemId,
        'item_unit_id': itemUnitId,
        'item_name': itemName,
        'item_hsn': itemHsn,
        'unit_name': unitName,
        'quantity': quantity,
        'conversion_factor': conversionFactor,
        'unit_price': unitPrice,
        'mrp': mrp,
        'discount_type': discountType,
        'discount_value': discountValue,
        'discount_amount': discountAmount,
        'taxable_amount': taxableAmount,
        'tax_rate_id': taxRateId,
        'tax_rate': taxRate,
        'tax_amount': taxAmount,
        'cgst_amount': cgstAmount,
        'sgst_amount': sgstAmount,
        'igst_amount': igstAmount,
        'tax_inclusive': taxInclusive ? 1 : 0,
        'total_amount': totalAmount,
        'sort_order': sortOrder,
        'notes': notes,
      };
}
