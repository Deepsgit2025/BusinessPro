/// A payment mode (Cash, UPI, Bank Transfer, …). Maps to `payment_modes`.
class PaymentMode {
  final int? id;
  final int businessId;
  final String name;
  final String type; // 'cash' | 'digital' | 'credit'
  final bool isActive;

  const PaymentMode({
    this.id,
    this.businessId = 1,
    required this.name,
    this.type = 'digital',
    this.isActive = true,
  });

  bool get isCredit => type == 'credit';

  factory PaymentMode.fromMap(Map<String, dynamic> m) => PaymentMode(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        name: (m['name'] as String?) ?? '',
        type: (m['type'] as String?) ?? 'digital',
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
      );
}
