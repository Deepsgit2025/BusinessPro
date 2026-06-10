// Lightweight value types returned by ReportsRepository. Each report screen
// consumes one of these instead of raw row maps, so the SQL stays in the
// repository and the UI/export layers stay type-safe.

/// A single line in the Day Book / Sale / Purchase reports.
class TxnReportRow {
  final int id;
  final String date; // ISO
  final String number;
  final String type;
  final String? partyName;
  final double total;
  final double paid;
  final double balance;
  final String paymentStatus;

  const TxnReportRow({
    required this.id,
    required this.date,
    required this.number,
    required this.type,
    required this.partyName,
    required this.total,
    required this.paid,
    required this.balance,
    required this.paymentStatus,
  });

  factory TxnReportRow.fromMap(Map<String, dynamic> m) => TxnReportRow(
        id: m['id'] as int,
        date: (m['transaction_date'] as String?) ?? '',
        number: (m['transaction_number'] as String?) ?? '',
        type: (m['transaction_type'] as String?) ?? '',
        partyName: m['party_name'] as String?,
        total: (m['total_amount'] as num?)?.toDouble() ?? 0,
        paid: (m['paid_amount'] as num?)?.toDouble() ?? 0,
        balance: (m['balance_amount'] as num?)?.toDouble() ?? 0,
        paymentStatus: (m['payment_status'] as String?) ?? 'unpaid',
      );
}

/// Result of the Profit & Loss report.
class ProfitLoss {
  final double totalSale;
  final double totalPurchase;
  final double totalExpense;
  final double totalIncome;

  const ProfitLoss({
    required this.totalSale,
    required this.totalPurchase,
    required this.totalExpense,
    required this.totalIncome,
  });

  double get grossProfit => totalSale - totalPurchase;
  double get netProfit => grossProfit + totalIncome - totalExpense;
  double get netProfitPct => totalSale == 0 ? 0 : (netProfit / totalSale) * 100;
}

/// One party's outstanding receivable / payable bucket.
class OutstandingRow {
  final int partyId;
  final String partyName;
  final String? phone;
  final int invoiceCount;
  final double totalOutstanding;
  final String? oldestInvoiceDate; // ISO
  final String? latestInvoiceDate;
  // Aging buckets, filled in by the repository from the per-invoice rows.
  final double bucket0to30;
  final double bucket31to60;
  final double bucket60plus;

  const OutstandingRow({
    required this.partyId,
    required this.partyName,
    required this.phone,
    required this.invoiceCount,
    required this.totalOutstanding,
    required this.oldestInvoiceDate,
    required this.latestInvoiceDate,
    required this.bucket0to30,
    required this.bucket31to60,
    required this.bucket60plus,
  });
}

/// A party statement ledger line with a running balance.
class StatementRow {
  final String date;
  final String number;
  final String type;
  final double debit; // increases what the party owes us (sales)
  final double credit; // decreases it (payments / returns)
  final double runningBalance;

  const StatementRow({
    required this.date,
    required this.number,
    required this.type,
    required this.debit,
    required this.credit,
    required this.runningBalance,
  });
}

/// A stock-summary / low-stock line.
class StockRow {
  final int itemId;
  final String name;
  final double currentStock;
  final double minStockLevel;
  final String? categoryName;
  final String? baseUnit;
  final double purchasePrice;
  final double salePrice;

  const StockRow({
    required this.itemId,
    required this.name,
    required this.currentStock,
    required this.minStockLevel,
    required this.categoryName,
    required this.baseUnit,
    required this.purchasePrice,
    required this.salePrice,
  });

  double get stockValueAtCost => currentStock * purchasePrice;
  double get stockValueAtSale => currentStock * salePrice;
  double get unitsBelowMin => minStockLevel - currentStock;

  factory StockRow.fromMap(Map<String, dynamic> m) => StockRow(
        itemId: m['id'] as int,
        name: (m['name'] as String?) ?? '',
        currentStock: (m['current_stock'] as num?)?.toDouble() ?? 0,
        minStockLevel: (m['min_stock_level'] as num?)?.toDouble() ?? 0,
        categoryName: m['category_name'] as String?,
        baseUnit: m['base_unit'] as String?,
        purchasePrice: (m['purchase_price'] as num?)?.toDouble() ?? 0,
        salePrice: (m['sale_price'] as num?)?.toDouble() ?? 0,
      );
}

/// An expense-report category breakdown line.
class ExpenseCategoryRow {
  final String categoryName;
  final int count;
  final double total;

  const ExpenseCategoryRow({
    required this.categoryName,
    required this.count,
    required this.total,
  });

  factory ExpenseCategoryRow.fromMap(Map<String, dynamic> m) =>
      ExpenseCategoryRow(
        categoryName: (m['category_name'] as String?) ?? 'Uncategorised',
        count: (m['transaction_count'] as int?) ?? 0,
        total: (m['total_amount'] as num?)?.toDouble() ?? 0,
      );
}
