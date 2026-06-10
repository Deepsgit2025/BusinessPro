/// A GST / tax rate. Maps to the `tax_rates` table.
class TaxRate {
  final int? id;
  final int businessId;
  final String name;
  final double rate;
  final double cgstRate;
  final double sgstRate;
  final double igstRate;
  final bool isActive;

  const TaxRate({
    this.id,
    this.businessId = 1,
    required this.name,
    this.rate = 0,
    this.cgstRate = 0,
    this.sgstRate = 0,
    this.igstRate = 0,
    this.isActive = true,
  });

  factory TaxRate.fromMap(Map<String, dynamic> m) => TaxRate(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        name: (m['name'] as String?) ?? '',
        rate: (m['rate'] as num?)?.toDouble() ?? 0,
        cgstRate: (m['cgst_rate'] as num?)?.toDouble() ?? 0,
        sgstRate: (m['sgst_rate'] as num?)?.toDouble() ?? 0,
        igstRate: (m['igst_rate'] as num?)?.toDouble() ?? 0,
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
      );

  Map<String, dynamic> toMap() => {
        'business_id': businessId,
        'name': name,
        'rate': rate,
        'cgst_rate': cgstRate,
        'sgst_rate': sgstRate,
        'igst_rate': igstRate,
        'is_active': isActive ? 1 : 0,
      };
}
