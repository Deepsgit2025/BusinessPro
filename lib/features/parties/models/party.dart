/// A customer or supplier in the address book.
///
/// Maps to the `parties` table. The list-screen query also pulls aggregate
/// balance columns (`to_collect` / `to_pay`) that are not stored on the row —
/// those live in [toCollect] / [toPay] and default to 0 when absent.
class Party {
  final int? id;
  final int businessId;
  final String name;
  final String partyType; // 'customer' | 'supplier' | 'both'
  final String? phone;
  final String? alternatePhone;
  final String? email;
  final String? gstin;
  final String? panNumber;
  final double creditLimit;
  final int creditDays;
  final double openingBalance;
  final String openingBalanceType; // 'debit' (To Collect) | 'credit' (To Pay)
  final String? billingAddress;
  final String? billingCity;
  final String? billingState;
  final String? billingPincode;
  final String? notes;
  final bool isActive;

  // Aggregates from the list query (not persisted on the row itself).
  final double toCollect;
  final double toPay;

  const Party({
    this.id,
    this.businessId = 1,
    required this.name,
    this.partyType = 'customer',
    this.phone,
    this.alternatePhone,
    this.email,
    this.gstin,
    this.panNumber,
    this.creditLimit = 0,
    this.creditDays = 0,
    this.openingBalance = 0,
    this.openingBalanceType = 'debit',
    this.billingAddress,
    this.billingCity,
    this.billingState,
    this.billingPincode,
    this.notes,
    this.isActive = true,
    this.toCollect = 0,
    this.toPay = 0,
  });

  /// Net balance including the opening balance.
  /// Positive ⇒ To Collect (they owe you). Negative ⇒ To Pay (you owe them).
  double get netBalance {
    final opening = openingBalanceType == 'debit' ? openingBalance : -openingBalance;
    return opening + toCollect - toPay;
  }

  bool get isCustomer => partyType == 'customer' || partyType == 'both';
  bool get isSupplier => partyType == 'supplier' || partyType == 'both';

  factory Party.fromMap(Map<String, dynamic> m) => Party(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        name: (m['name'] as String?) ?? '',
        partyType: (m['party_type'] as String?) ?? 'customer',
        phone: m['phone'] as String?,
        alternatePhone: m['alternate_phone'] as String?,
        email: m['email'] as String?,
        gstin: m['gstin'] as String?,
        panNumber: m['pan_number'] as String?,
        creditLimit: (m['credit_limit'] as num?)?.toDouble() ?? 0,
        creditDays: (m['credit_days'] as int?) ?? 0,
        openingBalance: (m['opening_balance'] as num?)?.toDouble() ?? 0,
        openingBalanceType: (m['opening_balance_type'] as String?) ?? 'debit',
        billingAddress: m['billing_address'] as String?,
        billingCity: m['billing_city'] as String?,
        billingState: m['billing_state'] as String?,
        billingPincode: m['billing_pincode'] as String?,
        notes: m['notes'] as String?,
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
        toCollect: (m['to_collect'] as num?)?.toDouble() ?? 0,
        toPay: (m['to_pay'] as num?)?.toDouble() ?? 0,
      );

  /// Column map for insert/update. Excludes `id`, aggregates, and timestamps
  /// (timestamps are set by the repository).
  Map<String, dynamic> toMap() => {
        'business_id': businessId,
        'name': name,
        'party_type': partyType,
        'phone': phone,
        'alternate_phone': alternatePhone,
        'email': email,
        'gstin': gstin,
        'pan_number': panNumber,
        'credit_limit': creditLimit,
        'credit_days': creditDays,
        'opening_balance': openingBalance,
        'opening_balance_type': openingBalanceType,
        'billing_address': billingAddress,
        'billing_city': billingCity,
        'billing_state': billingState,
        'billing_pincode': billingPincode,
        'notes': notes,
        'is_active': isActive ? 1 : 0,
      };
}
