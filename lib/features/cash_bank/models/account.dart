/// A cash / bank / wallet account. Maps to the `accounts` table.
class Account {
  final int? id;
  final int businessId;
  final String name;
  final String accountType; // 'cash' | 'bank' | 'wallet'
  final String? bankName;
  final String? accountNumber;
  final String? ifscCode;
  final double openingBalance;
  final double currentBalance;
  final bool isDefault;
  final bool isActive;

  const Account({
    this.id,
    this.businessId = 1,
    required this.name,
    this.accountType = 'cash',
    this.bankName,
    this.accountNumber,
    this.ifscCode,
    this.openingBalance = 0,
    this.currentBalance = 0,
    this.isDefault = false,
    this.isActive = true,
  });

  factory Account.fromMap(Map<String, dynamic> m) => Account(
        id: m['id'] as int?,
        businessId: (m['business_id'] as int?) ?? 1,
        name: (m['name'] as String?) ?? '',
        accountType: (m['account_type'] as String?) ?? 'cash',
        bankName: m['bank_name'] as String?,
        accountNumber: m['account_number'] as String?,
        ifscCode: m['ifsc_code'] as String?,
        openingBalance: (m['opening_balance'] as num?)?.toDouble() ?? 0,
        currentBalance: (m['current_balance'] as num?)?.toDouble() ?? 0,
        isDefault: ((m['is_default'] as int?) ?? 0) == 1,
        isActive: ((m['is_active'] as int?) ?? 1) == 1,
      );

  /// Column map for insert/update. current_balance is handled by the repository
  /// (seeded from opening_balance on insert; left untouched on edit so payment
  /// triggers keep driving it).
  Map<String, dynamic> toMap() => {
        'business_id': businessId,
        'name': name,
        'account_type': accountType,
        'bank_name': bankName,
        'account_number': accountNumber,
        'ifsc_code': ifscCode,
        'opening_balance': openingBalance,
        'is_default': isDefault ? 1 : 0,
        'is_active': isActive ? 1 : 0,
      };
}
