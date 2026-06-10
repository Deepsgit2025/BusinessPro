/// An expense / income category. Maps to `expense_categories`.
class ExpenseCategory {
  final int? id;
  final int businessId;
  final String name;
  final String categoryFor; // 'expense' | 'income' | 'both'
  final bool isActive;

  const ExpenseCategory({
    this.id,
    this.businessId = 1,
    required this.name,
    this.categoryFor = 'expense',
    this.isActive = true,
  });

  factory ExpenseCategory.fromMap(Map<String, dynamic> m) => ExpenseCategory(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        name: (m['name'] as String?) ?? '',
        categoryFor: (m['category_for'] as String?) ?? 'expense',
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
      );

  Map<String, dynamic> toMap() => {
        'business_id': businessId,
        'name': name,
        'category_for': categoryFor,
        'is_active': isActive ? 1 : 0,
      };
}
