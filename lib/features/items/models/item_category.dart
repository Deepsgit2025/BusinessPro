/// An item group / category. Maps to the `item_categories` table.
class ItemCategory {
  final int? id;
  final int businessId;
  final String name;
  final String? description;
  final bool isActive;

  // Aggregate from the management-screen query (not persisted).
  final int itemCount;

  const ItemCategory({
    this.id,
    this.businessId = 1,
    required this.name,
    this.description,
    this.isActive = true,
    this.itemCount = 0,
  });

  factory ItemCategory.fromMap(Map<String, dynamic> m) => ItemCategory(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        name: (m['name'] as String?) ?? '',
        description: m['description'] as String?,
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
        itemCount: (m['item_count'] as int?) ?? 0,
      );

  Map<String, dynamic> toMap() => {
        'business_id': businessId,
        'name': name,
        'description': description,
        'is_active': isActive ? 1 : 0,
      };
}
