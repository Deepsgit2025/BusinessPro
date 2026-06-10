/// A payment against a transaction. Maps to the `payments` table.
///
/// Inserting a payment row fires DB triggers that update the transaction's
/// paid_amount / balance_amount / payment_status and the account balance — so
/// callers must NOT also update those manually.
class Payment {
  final int? id;
  final int? transactionId;
  final int? accountId;
  final int? paymentModeId;
  final double amount;
  final String paymentDate; // ISO 8601 / yyyy-MM-dd
  final String? referenceNumber;
  final String? notes;

  // Joined view data (not persisted on the payments row).
  final String? modeName;
  final String? accountName;

  const Payment({
    this.id,
    this.transactionId,
    this.accountId,
    this.paymentModeId,
    required this.amount,
    required this.paymentDate,
    this.referenceNumber,
    this.notes,
    this.modeName,
    this.accountName,
  });

  factory Payment.fromMap(Map<String, dynamic> m) => Payment(
        id: m['id'] as int?,
        transactionId: m['transaction_id'] as int?,
        accountId: m['account_id'] as int?,
        paymentModeId: m['payment_mode_id'] as int?,
        amount: (m['amount'] as num?)?.toDouble() ?? 0,
        paymentDate: (m['payment_date'] as String?) ?? '',
        referenceNumber: m['reference_number'] as String?,
        notes: m['notes'] as String?,
        modeName: m['mode_name'] as String?,
        accountName: m['account_name'] as String?,
      );

  Map<String, dynamic> toMap() => {
        if (transactionId != null) 'transaction_id': transactionId,
        'account_id': accountId,
        'payment_mode_id': paymentModeId,
        'amount': amount,
        'payment_date': paymentDate,
        'reference_number': referenceNumber,
        'notes': notes,
      };
}
