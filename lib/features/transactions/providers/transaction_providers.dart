import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cash_bank/models/account.dart';
import '../../cash_bank/repositories/account_repository.dart';
import '../models/expense_category.dart';
import '../models/payment.dart';
import '../models/payment_mode.dart';
import '../models/transaction.dart';
import '../models/transaction_item.dart';
import '../repositories/transaction_repository.dart';
import '../repositories/txn_meta_repository.dart';
import '../../../services/sync/sync_providers.dart';

// ── Repositories ────────────────────────────────────────────────────────────
final transactionRepositoryProvider =
    Provider<TransactionRepository>((ref) => TransactionRepository());
final txnMetaRepositoryProvider =
    Provider<TxnMetaRepository>((ref) => TxnMetaRepository());
final accountRepositoryProvider =
    Provider<AccountRepository>((ref) => AccountRepository());

// ── Master data ─────────────────────────────────────────────────────────────
final paymentModesProvider = FutureProvider<List<PaymentMode>>((ref) async {
  return ref.watch(txnMetaRepositoryProvider).paymentModes();
});

final accountsProvider = FutureProvider<List<Account>>((ref) async {
  return ref.watch(accountRepositoryProvider).getAccounts();
});

/// Expense or income categories, keyed by 'expense' / 'income'.
final categoriesProvider =
    FutureProvider.family<List<ExpenseCategory>, String>((ref, categoryFor) async {
  return ref.watch(txnMetaRepositoryProvider).categories(categoryFor);
});

// ── List filters ────────────────────────────────────────────────────────────

/// Filter state shared by the sale/purchase/expense/income list screens.
/// status: 'all' | 'paid' | 'unpaid' | 'partial'.
class TxnListFilter {
  final String status;
  final String search;
  const TxnListFilter({this.status = 'all', this.search = ''});

  TxnListFilter copyWith({String? status, String? search}) =>
      TxnListFilter(status: status ?? this.status, search: search ?? this.search);
}

final saleFilterProvider = StateProvider<TxnListFilter>((ref) => const TxnListFilter());
final purchaseFilterProvider = StateProvider<TxnListFilter>((ref) => const TxnListFilter());

/// A named date range used by the Sale Return list's date filter.
class DateRange {
  final String label; // e.g. 'This Month'
  final DateTime from;
  final DateTime to;
  const DateRange({required this.label, required this.from, required this.to});

  /// The current calendar week (Monday 00:00 → Sunday 23:59:59).
  factory DateRange.thisWeek() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    final end = start.add(const Duration(days: 6));
    return DateRange(
      label: 'This Week',
      from: start,
      to: DateTime(end.year, end.month, end.day, 23, 59, 59),
    );
  }

  /// The current calendar month (1st 00:00 → last day 23:59:59).
  factory DateRange.thisMonth() {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, 1);
    final to = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
    return DateRange(label: 'This Month', from: from, to: to);
  }

  /// The current calendar quarter (3-month block → last day 23:59:59).
  factory DateRange.thisQuarter() {
    final now = DateTime.now();
    final startMonth = ((now.month - 1) ~/ 3) * 3 + 1;
    final from = DateTime(now.year, startMonth, 1);
    final to = DateTime(now.year, startMonth + 3, 0, 23, 59, 59);
    return DateRange(label: 'This Quarter', from: from, to: to);
  }

  /// The current calendar year (Jan 1 00:00 → Dec 31 23:59:59).
  factory DateRange.thisYear() {
    final now = DateTime.now();
    final from = DateTime(now.year, 1, 1);
    final to = DateTime(now.year, 12, 31, 23, 59, 59);
    return DateRange(label: 'This Year', from: from, to: to);
  }

  /// An explicit, user-picked date range.
  factory DateRange.custom(DateTime from, DateTime to) {
    return DateRange(
      label: 'Custom',
      from: DateTime(from.year, from.month, from.day),
      to: DateTime(to.year, to.month, to.day, 23, 59, 59),
    );
  }
}

final saleReturnRangeProvider =
    StateProvider<DateRange>((ref) => DateRange.thisMonth());

final purchaseReturnRangeProvider =
    StateProvider<DateRange>((ref) => DateRange.thisMonth());

/// Open/closed filter for the Estimate and Delivery Challan list screens.
/// 'all' shows everything; 'open' = still active; 'closed' = converted.
class DocListFilter {
  final String status; // 'all' | 'open' | 'closed'
  final String search;
  const DocListFilter({this.status = 'all', this.search = ''});

  DocListFilter copyWith({String? status, String? search}) =>
      DocListFilter(status: status ?? this.status, search: search ?? this.search);
}

final estimateFilterProvider =
    StateProvider<DocListFilter>((ref) => const DocListFilter());
final challanFilterProvider =
    StateProvider<DocListFilter>((ref) => const DocListFilter());

/// Applies the open/closed + search filter (in memory — `status` isn't a
/// column the repo's `list` filters on).
List<Transaction> _applyDocFilter(List<Transaction> txns, DocListFilter f) {
  return txns.where((t) {
    final statusOk = switch (f.status) {
      'open' => t.status == 'active',
      'closed' => t.status == 'converted',
      _ => true,
    };
    if (!statusOk) return false;
    if (f.search.trim().isEmpty) return true;
    final q = f.search.trim().toLowerCase();
    return t.transactionNumber.toLowerCase().contains(q) ||
        (t.partyName?.toLowerCase().contains(q) ?? false);
  }).toList();
}

final estimateListProvider = FutureProvider<List<Transaction>>((ref) async {
  final filter = ref.watch(estimateFilterProvider);
  final repo = ref.watch(transactionRepositoryProvider);
  final txns = await repo.list(const [TxnTypes.estimate]);
  return _applyDocFilter(txns, filter);
});

final challanListProvider = FutureProvider<List<Transaction>>((ref) async {
  final filter = ref.watch(challanFilterProvider);
  final repo = ref.watch(transactionRepositoryProvider);
  final txns = await repo.list(const [TxnTypes.deliveryChallan]);
  return _applyDocFilter(txns, filter);
});

// ── Lists ───────────────────────────────────────────────────────────────────

final saleListProvider = FutureProvider<List<Transaction>>((ref) async {
  final filter = ref.watch(saleFilterProvider);
  final repo = ref.watch(transactionRepositoryProvider);
  return repo.list(
    const [TxnTypes.sale, TxnTypes.estimate],
    paymentStatus: filter.status,
    search: filter.search,
  );
});

final saleSummaryProvider = FutureProvider<Map<String, double>>((ref) async {
  // Invalidated alongside the list; only sales (not estimates) count toward money.
  ref.watch(saleListProvider);
  return ref.watch(transactionRepositoryProvider).summary(const [TxnTypes.sale]);
});

/// Credit Notes (sale returns) within the selected date range, newest first.
final saleReturnListProvider = FutureProvider<List<Transaction>>((ref) async {
  final range = ref.watch(saleReturnRangeProvider);
  final repo = ref.watch(transactionRepositoryProvider);
  return repo.list(
    const [TxnTypes.saleReturn],
    from: range.from,
    to: range.to,
  );
});

/// Summary for the Sale Return list header: number of txns, total returned,
/// and outstanding balance — all scoped to the selected date range.
final saleReturnSummaryProvider =
    FutureProvider<({int count, double total, double balance})>((ref) async {
  final txns = await ref.watch(saleReturnListProvider.future);
  final total = txns.fold<double>(0, (s, t) => s + t.totalAmount);
  final balance = txns.fold<double>(0, (s, t) => s + t.balanceAmount);
  return (count: txns.length, total: total, balance: balance);
});

final purchaseListProvider = FutureProvider<List<Transaction>>((ref) async {
  final filter = ref.watch(purchaseFilterProvider);
  final repo = ref.watch(transactionRepositoryProvider);
  return repo.list(
    const [TxnTypes.purchase],
    paymentStatus: filter.status,
    search: filter.search,
  );
});

final purchaseSummaryProvider = FutureProvider<Map<String, double>>((ref) async {
  ref.watch(purchaseListProvider);
  return ref.watch(transactionRepositoryProvider).summary(const [TxnTypes.purchase]);
});

/// Debit Notes (purchase returns) within the selected date range, newest first.
final purchaseReturnListProvider = FutureProvider<List<Transaction>>((ref) async {
  final range = ref.watch(purchaseReturnRangeProvider);
  final repo = ref.watch(transactionRepositoryProvider);
  return repo.list(
    const [TxnTypes.purchaseReturn],
    from: range.from,
    to: range.to,
  );
});

/// Summary for the Purchase Return list header: count, total returned, balance.
final purchaseReturnSummaryProvider =
    FutureProvider<({int count, double total, double balance})>((ref) async {
  final txns = await ref.watch(purchaseReturnListProvider.future);
  final total = txns.fold<double>(0, (s, t) => s + t.totalAmount);
  final balance = txns.fold<double>(0, (s, t) => s + t.balanceAmount);
  return (count: txns.length, total: total, balance: balance);
});

final expenseListProvider = FutureProvider<List<Transaction>>((ref) async {
  final repo = ref.watch(transactionRepositoryProvider);
  return repo.list(const [TxnTypes.expense]);
});

final incomeListProvider = FutureProvider<List<Transaction>>((ref) async {
  final repo = ref.watch(transactionRepositoryProvider);
  return repo.list(const [TxnTypes.otherIncome]);
});

// ── Detail ──────────────────────────────────────────────────────────────────

/// Bundles a transaction with its lines and payments for the detail screen.
class TransactionDetail {
  final Transaction transaction;
  final List<TransactionItem> items;
  final List<Payment> payments;
  const TransactionDetail(this.transaction, this.items, this.payments);
}

final transactionDetailProvider =
    FutureProvider.family<TransactionDetail?, int>((ref, id) async {
  final repo = ref.watch(transactionRepositoryProvider);
  final txn = await repo.getById(id);
  if (txn == null) return null;
  final items = await repo.getItems(id);
  final payments = await repo.getPayments(id);
  return TransactionDetail(txn, items, payments);
});

/// Whether a transaction can still be edited (no payments recorded).
final transactionEditableProvider =
    FutureProvider.family<bool, int>((ref, id) async {
  return ref.watch(transactionRepositoryProvider).isEditable(id);
});

final recentTransactionsProvider = FutureProvider<List<Transaction>>((ref) async {
  final repo = ref.watch(transactionRepositoryProvider);
  final all = await repo.list(const [
    TxnTypes.sale,
    TxnTypes.purchase,
    TxnTypes.expense,
    TxnTypes.otherIncome,
  ]);
  return all.take(10).toList();
});

/// Recent transactions for the Sale module — only the 6 sale-side types.
final saleRecentProvider = FutureProvider<List<Transaction>>((ref) async {
  ref.watch(saleListProvider);
  final repo = ref.watch(transactionRepositoryProvider);
  final all = await repo.list(const [
    TxnTypes.sale,
    TxnTypes.paymentIn,
    TxnTypes.saleReturn,
    TxnTypes.estimate,
    TxnTypes.saleOrder,
    TxnTypes.deliveryChallan,
  ]);
  return all.take(20).toList();
});

/// Recent transactions for the Purchase module — only the 4 purchase-side types.
final purchaseRecentProvider = FutureProvider<List<Transaction>>((ref) async {
  ref.watch(purchaseListProvider);
  final repo = ref.watch(transactionRepositoryProvider);
  final all = await repo.list(const [
    TxnTypes.purchase,
    TxnTypes.paymentOut,
    TxnTypes.purchaseReturn,
    TxnTypes.purchaseOrder,
  ]);
  return all.take(20).toList();
});

// ── Helpers ─────────────────────────────────────────────────────────────────

/// Invalidates every list/summary/detail provider so screens refresh after a
/// write. Call from save / payment / cancel flows.
void invalidateTransactionData(Ref ref) {
  ref.invalidate(saleListProvider);
  ref.invalidate(saleSummaryProvider);
  ref.invalidate(saleRecentProvider);
  ref.invalidate(saleReturnListProvider);
  ref.invalidate(saleReturnSummaryProvider);
  ref.invalidate(estimateListProvider);
  ref.invalidate(challanListProvider);
  ref.invalidate(purchaseListProvider);
  ref.invalidate(purchaseSummaryProvider);
  ref.invalidate(purchaseRecentProvider);
  ref.invalidate(purchaseReturnListProvider);
  ref.invalidate(purchaseReturnSummaryProvider);
  ref.invalidate(expenseListProvider);
  ref.invalidate(incomeListProvider);
  ref.invalidate(recentTransactionsProvider);
  ref.invalidate(accountsProvider);
  // Phase 5: nudge a (debounced, silent) sync after any transaction write.
  try {
    ref.read(syncSchedulerProvider).onTransactionSaved();
  } catch (_) {/* sync not ready — periodic/resume triggers will catch up */}
}

extension TransactionDataRefresh on WidgetRef {
  void refreshTransactions() {
    invalidate(saleListProvider);
    invalidate(saleSummaryProvider);
    invalidate(saleRecentProvider);
    invalidate(saleReturnListProvider);
    invalidate(saleReturnSummaryProvider);
    invalidate(estimateListProvider);
    invalidate(challanListProvider);
    invalidate(purchaseListProvider);
    invalidate(purchaseSummaryProvider);
    invalidate(purchaseRecentProvider);
    invalidate(purchaseReturnListProvider);
    invalidate(purchaseReturnSummaryProvider);
    invalidate(expenseListProvider);
    invalidate(incomeListProvider);
    invalidate(recentTransactionsProvider);
    invalidate(accountsProvider);
    // Phase 5: trigger a debounced silent sync after the write.
    try {
      read(syncSchedulerProvider).onTransactionSaved();
    } catch (_) {/* sync not ready yet */}
  }
}
