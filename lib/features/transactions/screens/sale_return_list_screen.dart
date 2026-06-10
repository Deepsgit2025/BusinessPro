import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/transaction.dart';
import '../providers/transaction_providers.dart';
import 'add_edit_transaction_screen.dart';
import 'sale_detail_screen.dart';

/// Credit Note (Sale Return) list — opened from the "Sale Return" action.
///
/// Shows a date-range filter, a 3-card summary (count / total returned /
/// balance due) and a list of credit notes, with a FAB that opens the
/// Credit Note entry form.
class SaleReturnListScreen extends ConsumerWidget {
  const SaleReturnListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final range = ref.watch(saleReturnRangeProvider);
    final listAsync = ref.watch(saleReturnListProvider);
    final summaryAsync = ref.watch(saleReturnSummaryProvider);

    return Scaffold(
      backgroundColor: AppColors.background(context),
      appBar: AppBar(
        backgroundColor: AppColors.surface(context),
        foregroundColor: AppColors.textPrimaryOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: AppColors.dividerOf(context))),
        title: const Text('Sale Return',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          _DateFilterBar(range: range),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: _SummaryRow(summaryAsync: summaryAsync),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.refreshTransactions(),
              child: listAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => ListView(
                  children: [Center(child: Text('Error: $e'))],
                ),
                data: (txns) {
                  if (txns.isEmpty) {
                    return ListView(
                      children: const [
                        SizedBox(height: 80),
                        Center(
                          child: Text('No sale returns in this period',
                              style:
                                  TextStyle(color: AppColors.textSecondary)),
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                    itemCount: txns.length,
                    itemBuilder: (_, i) => _ReturnCard(
                      key: ValueKey(txns[i].id),
                      txn: txns[i],
                      onTap: () => _open(context, ref, txns[i]),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.expense,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Add Sale Return',
            style: TextStyle(fontWeight: FontWeight.w600)),
        onPressed: () => _openCreate(context, ref),
      ),
    );
  }

  Future<void> _openCreate(BuildContext context, WidgetRef ref) async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            const AddEditTransactionScreen(mode: TxnFormMode.saleReturn),
      ),
    );
    if (created == true) ref.refreshTransactions();
  }

  Future<void> _open(
      BuildContext context, WidgetRef ref, Transaction txn) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SaleDetailScreen(transactionId: txn.id!),
      ),
    );
    ref.refreshTransactions();
  }
}

// ── Date filter bar ──────────────────────────────────────────────────────────

class _DateFilterBar extends ConsumerWidget {
  final DateRange range;
  const _DateFilterBar({required this.range});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      color: AppColors.surface(context),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          InkWell(
            onTap: () => _pickPreset(context, ref),
            borderRadius: BorderRadius.circular(4),
            child: Row(
              children: [
                Text(range.label,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w500)),
                const Icon(Icons.keyboard_arrow_down,
                    color: AppColors.partial),
              ],
            ),
          ),
          Container(
            width: 1,
            height: 24,
            color: AppColors.dividerOf(context),
            margin: const EdgeInsets.symmetric(horizontal: 12),
          ),
          Expanded(
            child: InkWell(
              onTap: () => _pickCustomRange(context, ref),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today_outlined,
                        size: 20, color: AppColors.partial),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${Formatters.dateShort(range.from)}   TO   '
                        '${Formatters.dateShort(range.to)}',
                        style: TextStyle(
                            fontSize: 14, color: AppColors.textPrimaryOf(context)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Shows the preset menu (This Week / Month / Quarter / Year) and applies
  /// the chosen range to [saleReturnRangeProvider].
  Future<void> _pickPreset(BuildContext context, WidgetRef ref) async {
    final presets = <String, DateRange Function()>{
      'This Week': DateRange.thisWeek,
      'This Month': DateRange.thisMonth,
      'This Quarter': DateRange.thisQuarter,
      'This Year': DateRange.thisYear,
    };
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final name in presets.keys)
              ListTile(
                title: Text(name),
                trailing: range.label == name
                    ? const Icon(Icons.check, color: AppColors.partial)
                    : null,
                onTap: () => Navigator.pop(context, name),
              ),
          ],
        ),
      ),
    );
    if (selected != null) {
      ref.read(saleReturnRangeProvider.notifier).state = presets[selected]!();
    }
  }

  /// Opens a date-range picker so the user can select an explicit period.
  Future<void> _pickCustomRange(BuildContext context, WidgetRef ref) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: DateTimeRange(start: range.from, end: range.to),
    );
    if (picked != null) {
      ref.read(saleReturnRangeProvider.notifier).state =
          DateRange.custom(picked.start, picked.end);
    }
  }
}

// ── Summary row (3 metric cards) ─────────────────────────────────────────────

class _SummaryRow extends StatelessWidget {
  final AsyncValue<({int count, double total, double balance})> summaryAsync;
  const _SummaryRow({required this.summaryAsync});

  @override
  Widget build(BuildContext context) {
    final s = summaryAsync.valueOrNull;
    return Row(
      children: [
        Expanded(
          child: _MetricCard(
            label: 'No of Txns',
            value: '${s?.count ?? 0}',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _MetricCard(
            label: 'Total Sale Return',
            value: '- ${Formatters.currency(s?.total ?? 0)}',
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _MetricCard(
            label: 'Balance Due',
            value: Formatters.currency(s?.balance ?? 0),
            valueColor: AppColors.expense,
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _MetricCard({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.dividerOf(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  fontSize: 13, color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: valueColor ?? AppColors.textPrimaryOf(context))),
        ],
      ),
    );
  }
}

// ── Transaction card ─────────────────────────────────────────────────────────

class _ReturnCard extends StatelessWidget {
  final Transaction txn;
  final VoidCallback onTap;
  const _ReturnCard({super.key, required this.txn, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppColors.dividerOf(context)),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      txn.partyName?.isNotEmpty == true
                          ? txn.partyName!
                          : 'Cash Sale',
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(txn.transactionNumber,
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                      const SizedBox(height: 2),
                      Text(
                        Formatters.date(txn.transactionDate).toUpperCase(),
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _AmountBlock(
                        label: 'Amount',
                        value: Formatters.currency(txn.totalAmount)),
                  ),
                  Expanded(
                    child: _AmountBlock(
                        label: 'Balance',
                        value: Formatters.currency(txn.balanceAmount)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AmountBlock extends StatelessWidget {
  final String label;
  final String value;
  const _AmountBlock({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Text(value,
            style:
                const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
