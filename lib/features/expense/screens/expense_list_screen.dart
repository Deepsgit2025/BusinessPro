import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../transactions/models/transaction.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../../transactions/screens/add_edit_cash_txn_screen.dart';

/// Expense list (drawer → Expense) and Income list (drawer → Income) share this
/// screen, switched by [isIncome]. Shows a this-month total, category filter
/// chips, and a card per transaction.
class ExpenseListScreen extends ConsumerStatefulWidget {
  final bool isIncome;
  const ExpenseListScreen({super.key, this.isIncome = false});

  @override
  ConsumerState<ExpenseListScreen> createState() => _ExpenseListScreenState();
}

class _ExpenseListScreenState extends ConsumerState<ExpenseListScreen> {
  String? _categoryFilter; // null ⇒ All

  bool get _isIncome => widget.isIncome;
  String get _title => _isIncome ? 'Income' : 'Expense';

  @override
  Widget build(BuildContext context) {
    final listAsync =
        ref.watch(_isIncome ? incomeListProvider : expenseListProvider);

    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.add, color: Colors.white),
        label: Text('Add $_title',
            style: const TextStyle(color: Colors.white)),
        onPressed: () async {
          final r = await Navigator.push<bool>(
            context,
            MaterialPageRoute(
              builder: (_) => AddEditCashTxnScreen(isIncome: _isIncome),
            ),
          );
          if (r == true) ref.refreshTransactions();
        },
      ),
      body: listAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rows) {
          // Month-to-date total over all rows.
          final now = DateTime.now();
          final monthTotal = rows
              .where((t) {
                final d = DateTime.tryParse(t.transactionDate);
                return d != null && d.year == now.year && d.month == now.month;
              })
              .fold<double>(0, (sum, t) => sum + t.totalAmount);

          // Distinct categories present, for the filter chips.
          final categories = <String>{
            for (final t in rows)
              if (t.categoryName != null) t.categoryName!
          }.toList()
            ..sort();

          final filtered = _categoryFilter == null
              ? rows
              : rows.where((t) => t.categoryName == _categoryFilter).toList();

          return Column(
            children: [
              _MonthSummary(total: monthTotal, isIncome: _isIncome),
              if (categories.isNotEmpty)
                _CategoryChips(
                  categories: categories,
                  selected: _categoryFilter,
                  onChanged: (c) => setState(() => _categoryFilter = c),
                ),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyState(isIncome: _isIncome)
                    : RefreshIndicator(
                        onRefresh: () async => ref.refreshTransactions(),
                        child: ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: filtered.length,
                          itemBuilder: (context, i) =>
                              _CashCard(txn: filtered[i], isIncome: _isIncome),
                        ),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MonthSummary extends StatelessWidget {
  final double total;
  final bool isIncome;
  const _MonthSummary({required this.total, required this.isIncome});

  @override
  Widget build(BuildContext context) {
    final color = isIncome ? AppColors.income : AppColors.expense;
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.07),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('This Month',
              style: const TextStyle(
                  fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(Formatters.currency(total),
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: color)),
        ],
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onChanged;
  const _CategoryChips({
    required this.categories,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: const Text('All'),
              selected: selected == null,
              onSelected: (_) => onChanged(null),
            ),
          ),
          ...categories.map((c) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(c),
                  selected: selected == c,
                  onSelected: (_) => onChanged(c),
                ),
              )),
        ],
      ),
    );
  }
}

class _CashCard extends StatelessWidget {
  final Transaction txn;
  final bool isIncome;
  const _CashCard({required this.txn, required this.isIncome});

  @override
  Widget build(BuildContext context) {
    final color = isIncome ? AppColors.income : AppColors.expense;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: color.withValues(alpha: 0.12),
              child: Icon(
                  isIncome ? Icons.south_west : Icons.north_east,
                  color: color,
                  size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(txn.categoryName ?? 'Uncategorised',
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      Formatters.date(txn.transactionDate),
                      if (txn.accountName != null) txn.accountName!,
                    ].join(' · '),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                  if (txn.notes != null && txn.notes!.isNotEmpty)
                    Text(txn.notes!,
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textHint),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
            Text(Formatters.currency(txn.totalAmount),
                style: TextStyle(
                    color: color, fontWeight: FontWeight.bold, fontSize: 15)),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final bool isIncome;
  const _EmptyState({required this.isIncome});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(isIncome ? Icons.attach_money : Icons.money_off,
              size: 64, color: AppColors.textHint),
          const SizedBox(height: 12),
          Text('No ${isIncome ? 'income' : 'expenses'} yet',
              style: const TextStyle(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
