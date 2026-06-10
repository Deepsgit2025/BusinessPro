import '../../../core/database/database_helper.dart';
import '../models/report_models.dart';

/// An inclusive [start, end] date window for report filtering. The repository
/// translates it into a half-open `>= startOfDay AND < startOfNextDay` SQL range
/// so the whole end day is captured regardless of any time component stored on
/// `transaction_date` (which is ISO 8601, often with a time part).
class DateRange {
  final DateTime start;
  final DateTime end;
  const DateRange(this.start, this.end);

  /// First instant of the start day (local).
  String get startIso =>
      DateTime(start.year, start.month, start.day).toIso8601String();

  /// First instant of the day *after* the end day, so `< endExclusiveIso`
  /// includes everything dated on the end day.
  String get endExclusiveIso =>
      DateTime(end.year, end.month, end.day).add(const Duration(days: 1))
          .toIso8601String();

  static DateRange thisMonth() {
    final now = DateTime.now();
    return DateRange(DateTime(now.year, now.month, 1), now);
  }

  static DateRange thisYear() {
    final now = DateTime.now();
    return DateRange(DateTime(now.year, 1, 1), now);
  }
}

/// Read-only data access for the Reports module. Every method runs SELECTs only
/// — report screens never mutate data. All queries are scoped to the single
/// business (id = 1) and exclude soft-deleted rows.
class ReportsRepository {
  static const _businessId = 1;

  // ── Report 1: Day Book ─────────────────────────────────────────────────────

  /// Every transaction on a single [date], oldest first.
  Future<List<TxnReportRow>> dayBook(DateTime date) async {
    final db = await DatabaseHelper.database;
    final range = DateRange(date, date);
    final rows = await db.rawQuery('''
      SELECT t.*, p.name AS party_name
      FROM transactions t
      LEFT JOIN parties p ON p.id = t.party_id
      WHERE t.business_id = ?
        AND t.transaction_date >= ? AND t.transaction_date < ?
        AND t.is_deleted = 0
      ORDER BY t.created_at ASC, t.id ASC
    ''', [_businessId, range.startIso, range.endExclusiveIso]);
    return rows.map(TxnReportRow.fromMap).toList();
  }

  // ── Reports 2 & 3: Sale / Purchase ─────────────────────────────────────────

  /// Sale or purchase transactions within [range]. Pass `'sale'` or
  /// `'purchase'` as [type]. Newest first.
  Future<List<TxnReportRow>> transactionsByType(
    String type,
    DateRange range,
  ) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT t.*, p.name AS party_name
      FROM transactions t
      LEFT JOIN parties p ON p.id = t.party_id
      WHERE t.business_id = ?
        AND t.transaction_type = ?
        AND t.transaction_date >= ? AND t.transaction_date < ?
        AND t.is_deleted = 0
      ORDER BY t.transaction_date DESC, t.id DESC
    ''', [_businessId, type, range.startIso, range.endExclusiveIso]);
    return rows.map(TxnReportRow.fromMap).toList();
  }

  // ── Report 4: Profit & Loss ────────────────────────────────────────────────

  Future<ProfitLoss> profitLoss(DateRange range) async {
    Future<double> sumFor(String type) async {
      final db = await DatabaseHelper.database;
      final rows = await db.rawQuery('''
        SELECT COALESCE(SUM(total_amount), 0) AS s
        FROM transactions
        WHERE business_id = ? AND transaction_type = ?
          AND transaction_date >= ? AND transaction_date < ?
          AND is_deleted = 0
      ''', [_businessId, type, range.startIso, range.endExclusiveIso]);
      return (rows.first['s'] as num?)?.toDouble() ?? 0;
    }

    return ProfitLoss(
      totalSale: await sumFor('sale'),
      totalPurchase: await sumFor('purchase'),
      totalExpense: await sumFor('expense'),
      totalIncome: await sumFor('other_income'),
    );
  }

  /// Monthly sale vs purchase totals for the P&L trend chart, over the last
  /// [months] calendar months (oldest first). Each entry: (label, sale, purchase).
  Future<List<({String label, double sale, double purchase})>> monthlyTrend({
    int months = 6,
  }) async {
    final db = await DatabaseHelper.database;
    final now = DateTime.now();
    final result = <({String label, double sale, double purchase})>[];
    const monthNames = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];

    for (var i = months - 1; i >= 0; i--) {
      final m = DateTime(now.year, now.month - i, 1);
      final next = DateTime(m.year, m.month + 1, 1);
      final rows = await db.rawQuery('''
        SELECT
          COALESCE(SUM(CASE WHEN transaction_type = 'sale'     THEN total_amount END), 0) AS sale,
          COALESCE(SUM(CASE WHEN transaction_type = 'purchase' THEN total_amount END), 0) AS purchase
        FROM transactions
        WHERE business_id = ?
          AND transaction_date >= ? AND transaction_date < ?
          AND is_deleted = 0
      ''', [_businessId, m.toIso8601String(), next.toIso8601String()]);
      result.add((
        label: monthNames[m.month - 1],
        sale: (rows.first['sale'] as num?)?.toDouble() ?? 0,
        purchase: (rows.first['purchase'] as num?)?.toDouble() ?? 0,
      ));
    }
    return result;
  }

  // ── Report 5: Party Statement ──────────────────────────────────────────────

  /// Running ledger for one [partyId]. The opening balance is seeded from the
  /// party row, then each sale adds to (debit) and each payment/return reduces
  /// (credit) the running balance, oldest first.
  Future<List<StatementRow>> partyStatement(int partyId) async {
    final db = await DatabaseHelper.database;

    final partyRows = await db.query('parties',
        columns: ['opening_balance', 'opening_balance_type'],
        where: 'id = ?', whereArgs: [partyId], limit: 1);
    double opening = 0;
    if (partyRows.isNotEmpty) {
      final ob = (partyRows.first['opening_balance'] as num?)?.toDouble() ?? 0;
      final type = partyRows.first['opening_balance_type'] as String? ?? 'debit';
      // Debit opening ⇒ the party already owes us that amount.
      opening = type == 'debit' ? ob : -ob;
    }

    final rows = await db.rawQuery('''
      SELECT t.transaction_date, t.transaction_number, t.transaction_type,
             t.total_amount, t.paid_amount
      FROM transactions t
      WHERE t.party_id = ? AND t.is_deleted = 0
      ORDER BY t.transaction_date ASC, t.created_at ASC, t.id ASC
    ''', [partyId]);

    final statement = <StatementRow>[];
    var running = opening;
    if (opening != 0) {
      statement.add(StatementRow(
        date: '',
        number: 'Opening Balance',
        type: 'opening',
        debit: opening > 0 ? opening : 0,
        credit: opening < 0 ? -opening : 0,
        runningBalance: running,
      ));
    }

    for (final r in rows) {
      final type = (r['transaction_type'] as String?) ?? '';
      final total = (r['total_amount'] as num?)?.toDouble() ?? 0;
      final paid = (r['paid_amount'] as num?)?.toDouble() ?? 0;

      double debit = 0;
      double credit = 0;
      switch (type) {
        case 'sale':
          // Sale raises the balance owed; any amount paid against it lowers it.
          debit = total;
          credit = paid;
          break;
        case 'sale_return':
        case 'payment_in':
          credit = total;
          break;
        case 'purchase':
          // We owe the supplier: treat as a credit to the running balance.
          credit = total;
          debit = paid;
          break;
        case 'purchase_return':
        case 'payment_out':
          debit = total;
          break;
        default:
          debit = total;
      }
      running += debit - credit;
      statement.add(StatementRow(
        date: (r['transaction_date'] as String?) ?? '',
        number: (r['transaction_number'] as String?) ?? '',
        type: type,
        debit: debit,
        credit: credit,
        runningBalance: running,
      ));
    }
    return statement;
  }

  // ── Reports 6 & 7: Outstanding Receivables / Payables ──────────────────────

  /// Outstanding by party. Pass `'sale'` for receivables (who owes us) or
  /// `'purchase'` for payables (who we owe). Aging buckets are computed from the
  /// per-invoice balances against today.
  Future<List<OutstandingRow>> outstanding(String type) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT t.party_id, p.name AS party_name, p.phone,
             t.transaction_date, t.balance_amount
      FROM transactions t
      JOIN parties p ON p.id = t.party_id
      WHERE t.business_id = ?
        AND t.transaction_type = ?
        AND t.payment_status IN ('unpaid', 'partial')
        AND t.balance_amount > 0
        AND t.is_deleted = 0
      ORDER BY p.name ASC, t.transaction_date ASC
    ''', [_businessId, type]);

    final now = DateTime.now();
    final byParty = <int, _OutstandingAccum>{};
    for (final r in rows) {
      final pid = r['party_id'] as int;
      final acc = byParty.putIfAbsent(
        pid,
        () => _OutstandingAccum(
          partyName: (r['party_name'] as String?) ?? '',
          phone: r['phone'] as String?,
        ),
      );
      final bal = (r['balance_amount'] as num?)?.toDouble() ?? 0;
      final dateStr = (r['transaction_date'] as String?) ?? '';
      final date = DateTime.tryParse(dateStr);
      acc.count++;
      acc.total += bal;
      acc.oldest = _minDate(acc.oldest, dateStr);
      acc.latest = _maxDate(acc.latest, dateStr);

      final ageDays = date == null ? 0 : now.difference(date).inDays;
      if (ageDays <= 30) {
        acc.b0to30 += bal;
      } else if (ageDays <= 60) {
        acc.b31to60 += bal;
      } else {
        acc.b60plus += bal;
      }
    }

    final list = byParty.entries
        .map((e) => OutstandingRow(
              partyId: e.key,
              partyName: e.value.partyName,
              phone: e.value.phone,
              invoiceCount: e.value.count,
              totalOutstanding: e.value.total,
              oldestInvoiceDate: e.value.oldest,
              latestInvoiceDate: e.value.latest,
              bucket0to30: e.value.b0to30,
              bucket31to60: e.value.b31to60,
              bucket60plus: e.value.b60plus,
            ))
        .toList()
      ..sort((a, b) => b.totalOutstanding.compareTo(a.totalOutstanding));
    return list;
  }

  // ── Report 8: Stock Summary ────────────────────────────────────────────────

  Future<List<StockRow>> stockSummary() async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT i.id, i.name, i.current_stock, i.min_stock_level,
             c.name AS category_name,
             iu.unit_name AS base_unit,
             iu.purchase_price, iu.sale_price
      FROM items i
      LEFT JOIN item_categories c ON c.id = i.category_id
      LEFT JOIN item_units iu ON iu.item_id = i.id AND iu.is_base_unit = 1
      WHERE i.business_id = ? AND i.is_active = 1 AND i.item_type = 'product'
      ORDER BY i.name ASC
    ''', [_businessId]);
    return rows.map(StockRow.fromMap).toList();
  }

  // ── Report 9: Expense Report ───────────────────────────────────────────────

  Future<List<ExpenseCategoryRow>> expenseByCategory(DateRange range) async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT ec.name AS category_name,
             COUNT(t.id) AS transaction_count,
             SUM(t.total_amount) AS total_amount
      FROM transactions t
      JOIN expense_categories ec ON ec.id = t.category_id
      WHERE t.business_id = ?
        AND t.transaction_type = 'expense'
        AND t.transaction_date >= ? AND t.transaction_date < ?
        AND t.is_deleted = 0
      GROUP BY ec.id
      ORDER BY total_amount DESC
    ''', [_businessId, range.startIso, range.endExclusiveIso]);
    return rows.map(ExpenseCategoryRow.fromMap).toList();
  }

  // ── Report 10: Low Stock ───────────────────────────────────────────────────

  Future<List<StockRow>> lowStock() async {
    final db = await DatabaseHelper.database;
    final rows = await db.rawQuery('''
      SELECT i.id, i.name, i.current_stock, i.min_stock_level,
             c.name AS category_name,
             iu.unit_name AS base_unit,
             iu.purchase_price, iu.sale_price
      FROM items i
      LEFT JOIN item_categories c ON c.id = i.category_id
      LEFT JOIN item_units iu ON iu.item_id = i.id AND iu.is_base_unit = 1
      WHERE i.business_id = ?
        AND i.is_active = 1
        AND i.item_type = 'product'
        AND i.current_stock <= i.min_stock_level
      ORDER BY (i.current_stock - i.min_stock_level) ASC
    ''', [_businessId]);
    return rows.map(StockRow.fromMap).toList();
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  static String? _minDate(String? a, String b) {
    if (b.isEmpty) return a;
    if (a == null || a.isEmpty) return b;
    return b.compareTo(a) < 0 ? b : a;
  }

  static String? _maxDate(String? a, String b) {
    if (b.isEmpty) return a;
    if (a == null || a.isEmpty) return b;
    return b.compareTo(a) > 0 ? b : a;
  }
}

/// Mutable accumulator used while folding per-invoice rows into one party row.
class _OutstandingAccum {
  final String partyName;
  final String? phone;
  int count = 0;
  double total = 0;
  double b0to30 = 0;
  double b31to60 = 0;
  double b60plus = 0;
  String? oldest;
  String? latest;
  _OutstandingAccum({required this.partyName, required this.phone});
}
