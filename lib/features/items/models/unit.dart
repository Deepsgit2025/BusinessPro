/// A unit of measurement (e.g. Piece / pcs). Maps to the `units` table.
class Unit {
  final int? id;
  final int businessId;
  final String name;
  final String shortName;
  final bool isActive;

  const Unit({
    this.id,
    this.businessId = 1,
    required this.name,
    required this.shortName,
    this.isActive = true,
  });

  factory Unit.fromMap(Map<String, dynamic> m) => Unit(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        name: (m['name'] as String?) ?? '',
        shortName: (m['short_name'] as String?) ?? '',
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
      );

  Map<String, dynamic> toMap() => {
        'business_id': businessId,
        'name': name,
        'short_name': shortName,
        'is_active': isActive ? 1 : 0,
      };
}
