import '../../items/models/item_unit.dart';
import '../../items/models/tax_rate.dart';
import '../models/transaction_item.dart';

/// Mutable editing state for a single line on a transaction form. The add/edit
/// screen holds a list of these; each [ItemLineWidget] edits one in place. On
/// save they're frozen into [TransactionItem]s and run through [TxnCalc].
class LineDraft {
  // Identity / snapshot.
  int? itemId;
  String itemName;
  String? itemHsn;
  List<ItemUnit> tiers; // available selling units (empty for free-text lines)

  // Current selection.
  ItemUnit? selectedTier;
  String unitName;
  double conversionFactor;
  int? itemUnitId;

  // Editable inputs.
  double quantity;
  double unitPrice;
  String discountType; // 'none' | 'percent' | 'flat'
  double discountValue;

  // Tax.
  int? taxRateId;
  double taxRate;
  bool taxInclusive;
  double mrp;

  LineDraft({
    this.itemId,
    required this.itemName,
    this.itemHsn,
    this.tiers = const [],
    this.selectedTier,
    this.unitName = '',
    this.conversionFactor = 1,
    this.itemUnitId,
    this.quantity = 1,
    this.unitPrice = 0,
    this.discountType = 'none',
    this.discountValue = 0,
    this.taxRateId,
    this.taxRate = 0,
    this.taxInclusive = false,
    this.mrp = 0,
  });

  /// Applies a tier selection, syncing unit name / conversion / price for the
  /// given side ('sale' uses salePrice, 'purchase' uses purchasePrice).
  void applyTier(ItemUnit tier, {required bool isPurchase}) {
    selectedTier = tier;
    itemUnitId = tier.id;
    unitName = tier.unitName;
    conversionFactor = tier.conversionFactor;
    unitPrice = isPurchase ? tier.purchasePrice : tier.salePrice;
    mrp = tier.mrp;
  }

  /// Freezes this draft into a persistable line (pre-calculation). [TxnCalc]
  /// fills the derived money fields afterwards.
  TransactionItem toItem(int sortOrder) => TransactionItem(
        itemId: itemId,
        itemUnitId: itemUnitId,
        itemName: itemName,
        itemHsn: itemHsn,
        unitName: unitName.isEmpty ? null : unitName,
        quantity: quantity,
        conversionFactor: conversionFactor,
        unitPrice: unitPrice,
        mrp: mrp,
        discountType: discountType,
        discountValue: discountValue,
        taxRateId: taxRateId,
        taxRate: taxRate,
        taxInclusive: taxInclusive,
        sortOrder: sortOrder,
      );

  /// Rebuilds a draft from a saved line (edit flow), resolving its tier/tax from
  /// the supplied master lists where possible.
  factory LineDraft.fromItem(
    TransactionItem item, {
    List<ItemUnit> tiers = const [],
    List<TaxRate> taxRates = const [],
  }) {
    ItemUnit? tier;
    for (final t in tiers) {
      if (t.id == item.itemUnitId) {
        tier = t;
        break;
      }
    }
    return LineDraft(
      itemId: item.itemId,
      itemName: item.itemName,
      itemHsn: item.itemHsn,
      tiers: tiers,
      selectedTier: tier,
      itemUnitId: item.itemUnitId,
      unitName: item.unitName ?? '',
      conversionFactor: item.conversionFactor,
      quantity: item.quantity,
      unitPrice: item.unitPrice,
      discountType: item.discountType,
      discountValue: item.discountValue,
      taxRateId: item.taxRateId,
      taxRate: item.taxRate,
      taxInclusive: item.taxInclusive,
      mrp: item.mrp,
    );
  }
}
