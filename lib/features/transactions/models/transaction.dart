/// A master transaction record — one row per invoice / bill / estimate /
/// expense / income. Maps to the `transactions` table.
///
/// Line items live in [TransactionItem] (`transaction_items`) and payments in
/// [Payment] (`payments`). The list/detail queries also join the party name and
/// a paid-amount aggregate; those denormalised fields ([partyName]) are
/// read-only view data and are not written back by [toMap].
class TxnTypes {
  TxnTypes._();
  static const sale = 'sale';
  static const saleReturn = 'sale_return';
  static const saleOrder = 'sale_order';
  static const deliveryChallan = 'delivery_challan';
  static const estimate = 'estimate';
  static const purchase = 'purchase';
  static const purchaseReturn = 'purchase_return';
  static const purchaseOrder = 'purchase_order';
  static const expense = 'expense';
  static const otherIncome = 'other_income';
  static const paymentIn = 'payment_in';
  static const paymentOut = 'payment_out';
}

class Transaction {
  final int? id;
  final int businessId;
  final int? partyId;
  final int? accountId;
  final int? categoryId;
  final String transactionType;
  final String transactionNumber;
  final String? referenceNumber;
  /// Free-text customer/supplier name typed directly on the document, used when
  /// no [partyId] is set (a one-off party not saved to the party list). When a
  /// party IS linked, [partyName] (the joined name) is authoritative.
  final String? billingName;
  /// Free-text GSTIN / address for a one-off (no-party) document, mirroring
  /// [billingName]. Null when a party is linked (read off the party instead).
  final String? billingGstin;
  final String? billingAddress;
  final String transactionDate; // ISO 8601
  final String? dueDate;
  final double subtotal;
  final String discountType; // 'none' | 'percent' | 'flat'
  final double discountValue;
  final double discountAmount;
  final double taxableAmount;
  final double taxAmount;
  final double cgstAmount;
  final double sgstAmount;
  final double igstAmount;
  final double roundOff;
  final double totalAmount;
  final double paidAmount;
  final double balanceAmount;
  final String paymentStatus; // 'paid' | 'unpaid' | 'partial'
  final String status; // 'active' | 'cancelled' | 'draft' | 'converted'
  final String? notes;
  final String? termsConditions;
  final int? linkedTransactionId;
  final bool isDeleted;

  // Invoice Format 1: transport / delivery details (sale invoices). All optional.
  final String? ewayBillNumber;
  final String? placeOfSupply;
  final String? transportName;
  final String? vehicleNumber;
  final String? deliveryDate; // ISO 8601
  final String? deliveryLocation;

  // Shipping address (used when it differs from the party's billing address).
  final String? shippingAddress;
  final String? shippingCity;
  final String? shippingState;
  final String? shippingPincode;
  final bool isShippingDiff;

  // Joined view data (not persisted on the transactions row).
  final String? partyName;
  final String? categoryName;
  final String? accountName;

  const Transaction({
    this.id,
    this.businessId = 1,
    this.partyId,
    this.accountId,
    this.categoryId,
    required this.transactionType,
    required this.transactionNumber,
    this.referenceNumber,
    this.billingName,
    this.billingGstin,
    this.billingAddress,
    required this.transactionDate,
    this.dueDate,
    this.subtotal = 0,
    this.discountType = 'none',
    this.discountValue = 0,
    this.discountAmount = 0,
    this.taxableAmount = 0,
    this.taxAmount = 0,
    this.cgstAmount = 0,
    this.sgstAmount = 0,
    this.igstAmount = 0,
    this.roundOff = 0,
    this.totalAmount = 0,
    this.paidAmount = 0,
    this.balanceAmount = 0,
    this.paymentStatus = 'unpaid',
    this.status = 'active',
    this.notes,
    this.termsConditions,
    this.linkedTransactionId,
    this.isDeleted = false,
    this.ewayBillNumber,
    this.placeOfSupply,
    this.transportName,
    this.vehicleNumber,
    this.deliveryDate,
    this.deliveryLocation,
    this.shippingAddress,
    this.shippingCity,
    this.shippingState,
    this.shippingPincode,
    this.isShippingDiff = false,
    this.partyName,
    this.categoryName,
    this.accountName,
  });

  /// Name to show for the other party: the linked party's joined name when one
  /// exists, otherwise the free-text [billingName] typed on a one-off document.
  String? get displayPartyName =>
      (partyName != null && partyName!.trim().isNotEmpty)
          ? partyName
          : (billingName != null && billingName!.trim().isNotEmpty)
              ? billingName
              : null;

  bool get isCancelled => status == 'cancelled';
  bool get isPaid => paymentStatus == 'paid';
  bool get isUnpaid => paymentStatus == 'unpaid';
  bool get isPartial => paymentStatus == 'partial';
  bool get isInterState => igstAmount > 0;

  factory Transaction.fromMap(Map<String, dynamic> m) => Transaction(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        partyId: m['party_id'] as int?,
        accountId: m['account_id'] as int?,
        categoryId: m['category_id'] as int?,
        transactionType: (m['transaction_type'] as String?) ?? 'sale',
        transactionNumber: (m['transaction_number'] as String?) ?? '',
        referenceNumber: m['reference_number'] as String?,
        billingName: m['billing_name'] as String?,
        billingGstin: m['billing_gstin'] as String?,
        billingAddress: m['billing_address'] as String?,
        transactionDate: (m['transaction_date'] as String?) ?? '',
        dueDate: m['due_date'] as String?,
        subtotal: (m['subtotal'] as num?)?.toDouble() ?? 0,
        discountType: (m['discount_type'] as String?) ?? 'none',
        discountValue: (m['discount_value'] as num?)?.toDouble() ?? 0,
        discountAmount: (m['discount_amount'] as num?)?.toDouble() ?? 0,
        taxableAmount: (m['taxable_amount'] as num?)?.toDouble() ?? 0,
        taxAmount: (m['tax_amount'] as num?)?.toDouble() ?? 0,
        cgstAmount: (m['cgst_amount'] as num?)?.toDouble() ?? 0,
        sgstAmount: (m['sgst_amount'] as num?)?.toDouble() ?? 0,
        igstAmount: (m['igst_amount'] as num?)?.toDouble() ?? 0,
        roundOff: (m['round_off'] as num?)?.toDouble() ?? 0,
        totalAmount: (m['total_amount'] as num?)?.toDouble() ?? 0,
        paidAmount: (m['paid_amount'] as num?)?.toDouble() ?? 0,
        balanceAmount: (m['balance_amount'] as num?)?.toDouble() ?? 0,
        paymentStatus: (m['payment_status'] as String?) ?? 'unpaid',
        status: (m['status'] as String?) ?? 'active',
        notes: m['notes'] as String?,
        termsConditions: m['terms_conditions'] as String?,
        linkedTransactionId: m['linked_transaction_id'] as int?,
        isDeleted: ((m['is_deleted'] as int?) ?? 0) == 1,
        ewayBillNumber: m['eway_bill_number'] as String?,
        placeOfSupply: m['place_of_supply'] as String?,
        transportName: m['transport_name'] as String?,
        vehicleNumber: m['vehicle_number'] as String?,
        deliveryDate: m['delivery_date'] as String?,
        deliveryLocation: m['delivery_location'] as String?,
        shippingAddress: m['shipping_address'] as String?,
        shippingCity: m['shipping_city'] as String?,
        shippingState: m['shipping_state'] as String?,
        shippingPincode: m['shipping_pincode'] as String?,
        isShippingDiff: ((m['is_shipping_diff'] as int?) ?? 0) == 1,
        partyName: m['party_name'] as String?,
        categoryName: m['category_name'] as String?,
        accountName: m['account_name'] as String?,
      );

  /// Column map for insert/update. Excludes aggregates / joined view fields and
  /// timestamps (set by the repository). `paid_amount` / `balance_amount` /
  /// `payment_status` are driven by the payments trigger, so they're written
  /// only as the initial state on insert (see repository).
  Map<String, dynamic> toMap() => {
        'business_id': businessId,
        'party_id': partyId,
        'account_id': accountId,
        'category_id': categoryId,
        'transaction_type': transactionType,
        'transaction_number': transactionNumber,
        'reference_number': referenceNumber,
        'billing_name': billingName,
        'billing_gstin': billingGstin,
        'billing_address': billingAddress,
        'transaction_date': transactionDate,
        'due_date': dueDate,
        'subtotal': subtotal,
        'discount_type': discountType,
        'discount_value': discountValue,
        'discount_amount': discountAmount,
        'taxable_amount': taxableAmount,
        'tax_amount': taxAmount,
        'cgst_amount': cgstAmount,
        'sgst_amount': sgstAmount,
        'igst_amount': igstAmount,
        'round_off': roundOff,
        'total_amount': totalAmount,
        'paid_amount': paidAmount,
        'balance_amount': balanceAmount,
        'payment_status': paymentStatus,
        'status': status,
        'notes': notes,
        'terms_conditions': termsConditions,
        'linked_transaction_id': linkedTransactionId,
        'is_deleted': isDeleted ? 1 : 0,
        'eway_bill_number': ewayBillNumber,
        'place_of_supply': placeOfSupply,
        'transport_name': transportName,
        'vehicle_number': vehicleNumber,
        'delivery_date': deliveryDate,
        'delivery_location': deliveryLocation,
        'shipping_address': shippingAddress,
        'shipping_city': shippingCity,
        'shipping_state': shippingState,
        'shipping_pincode': shippingPincode,
        'is_shipping_diff': isShippingDiff ? 1 : 0,
      };
}
