import '../models/transaction_item.dart';

/// Pure calculation helpers for transaction totals. All money math runs here
/// (never trusting UI display values) so Sale / Purchase / Estimate share one
/// rounding-correct implementation.
///
/// GST split: intra-state ⇒ tax halved into CGST + SGST; inter-state ⇒ full
/// tax as IGST. The caller decides which by passing [interState].
class TxnCalc {
  TxnCalc._();

  /// Taxable amount for a single line = qty × price − discount.
  static double lineDiscount(
      double qty, double price, String discType, double discValue) {
    final lineTotal = qty * price;
    final disc = discType == 'percent' ? lineTotal * discValue / 100 : discValue;
    return disc.clamp(0, lineTotal);
  }

  static double lineTaxable(
      double qty, double price, String discType, double discValue) {
    return qty * price - lineDiscount(qty, price, discType, discValue);
  }

  /// Tax on a taxable amount. For tax-inclusive prices the tax is extracted from
  /// within the amount; otherwise it's added on top.
  static double lineTax(double taxableAmount, double taxRate, bool inclusive) {
    if (taxRate <= 0) return 0;
    if (inclusive) {
      return taxableAmount - (taxableAmount * 100 / (100 + taxRate));
    }
    return taxableAmount * taxRate / 100;
  }

  /// Re-computes every derived field on [line] from its qty / price / discount /
  /// tax inputs, splitting tax into CGST+SGST or IGST per [interState].
  ///
  /// For tax-inclusive lines the displayed [TransactionItem.totalAmount] equals
  /// qty × price − discount (tax already baked in); for exclusive lines the tax
  /// is added on top.
  static TransactionItem computeLine(TransactionItem line, {required bool interState}) {
    final taxable = lineTaxable(
        line.quantity, line.unitPrice, line.discountType, line.discountValue);
    final discount = lineDiscount(
        line.quantity, line.unitPrice, line.discountType, line.discountValue);
    final tax = lineTax(taxable, line.taxRate, line.taxInclusive);

    final cgst = interState ? 0.0 : tax / 2;
    final sgst = interState ? 0.0 : tax / 2;
    final igst = interState ? tax : 0.0;

    // Inclusive: tax already inside `taxable`, so total is just `taxable`.
    // Exclusive: tax added on top.
    final total = line.taxInclusive ? taxable : taxable + tax;
    // For inclusive lines, the "taxable amount" reported should be net of tax.
    final reportedTaxable = line.taxInclusive ? taxable - tax : taxable;

    return TransactionItem(
      id: line.id,
      transactionId: line.transactionId,
      itemId: line.itemId,
      itemUnitId: line.itemUnitId,
      itemName: line.itemName,
      itemHsn: line.itemHsn,
      unitName: line.unitName,
      quantity: line.quantity,
      conversionFactor: line.conversionFactor,
      unitPrice: line.unitPrice,
      mrp: line.mrp,
      discountType: line.discountType,
      discountValue: line.discountValue,
      discountAmount: discount,
      taxableAmount: reportedTaxable,
      taxRateId: line.taxRateId,
      taxRate: line.taxRate,
      taxAmount: tax,
      cgstAmount: cgst,
      sgstAmount: sgst,
      igstAmount: igst,
      taxInclusive: line.taxInclusive,
      totalAmount: total,
      sortOrder: line.sortOrder,
      notes: line.notes,
    );
  }

  /// Recomputes all lines then aggregates them into a [TxnTotals]. [interState]
  /// must match what [computeLine] used. Round-off snaps the grand total to the
  /// nearest rupee.
  static TxnTotals totals(List<TransactionItem> lines, {required bool interState}) {
    final computed =
        lines.map((l) => computeLine(l, interState: interState)).toList();

    double subtotal = 0; // sum of qty × price (pre-discount, pre-tax)
    double discount = 0;
    double taxable = 0;
    double cgst = 0, sgst = 0, igst = 0, tax = 0;

    for (final l in computed) {
      subtotal += l.quantity * l.unitPrice;
      discount += l.discountAmount;
      taxable += l.taxableAmount;
      cgst += l.cgstAmount;
      sgst += l.sgstAmount;
      igst += l.igstAmount;
      tax += l.taxAmount;
    }

    final preRound = taxable + tax;
    final rounded = preRound.roundToDouble();
    final roundOff = rounded - preRound;

    return TxnTotals(
      lines: computed,
      subtotal: subtotal,
      discountAmount: discount,
      taxableAmount: taxable,
      cgstAmount: cgst,
      sgstAmount: sgst,
      igstAmount: igst,
      taxAmount: tax,
      roundOff: roundOff,
      total: rounded,
      interState: interState,
    );
  }
}

/// Aggregated, calculation-ready totals for a transaction.
class TxnTotals {
  final List<TransactionItem> lines;
  final double subtotal;
  final double discountAmount;
  final double taxableAmount;
  final double cgstAmount;
  final double sgstAmount;
  final double igstAmount;
  final double taxAmount;
  final double roundOff;
  final double total;
  final bool interState;

  const TxnTotals({
    required this.lines,
    required this.subtotal,
    required this.discountAmount,
    required this.taxableAmount,
    required this.cgstAmount,
    required this.sgstAmount,
    required this.igstAmount,
    required this.taxAmount,
    required this.roundOff,
    required this.total,
    required this.interState,
  });
}
