import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/transaction.dart';
import '../providers/transaction_providers.dart';
import 'add_edit_transaction_screen.dart';
import 'sale_detail_screen.dart';

/// Which document module this list represents. Drives the title, the
/// transaction type, and which convert action / labels are shown.
enum DocKind { estimate, deliveryChallan }

/// List screen for Estimates/Quotations and Delivery Challans.
///
/// Shows All / Open / Closed status tabs, a search box, and a card per
/// document with an inline "Convert" action that turns an open document into a
/// Sale Invoice. A bottom FAB opens the entry form to add a new one.
class DocListScreen extends ConsumerWidget {
  final DocKind kind;
  const DocListScreen({super.key, required this.kind});

  bool get _isEstimate => kind == DocKind.estimate;

  String get _title =>
      _isEstimate ? 'Estimate Details' : 'Delivery Challan Details';

  String get _searchHint =>
      _isEstimate ? 'Search Estimate/Quotations' : 'Search Delivery Challan';

  String get _addLabel =>
      _isEstimate ? 'Add Estimate' : 'Add Delivery Challan';

  String get _convertLabel => _isEstimate ? 'Convert' : 'Convert to Sale';

  String get _emptyLabel => _isEstimate
      ? 'No estimates yet'
      : 'No delivery challans yet';

  StateProvider<DocListFilter> get _filterProvider =>
      _isEstimate ? estimateFilterProvider : challanFilterProvider;

  FutureProvider<List<Transaction>> get _listProvider =>
      _isEstimate ? estimateListProvider : challanListProvider;

  TxnFormMode get _formMode =>
      _isEstimate ? TxnFormMode.estimate : TxnFormMode.deliveryChallan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(_filterProvider);
    final listAsync = ref.watch(_listProvider);

    return Scaffold(
      backgroundColor: AppColors.background(context),
      appBar: AppBar(
        backgroundColor: AppColors.surface(context),
        foregroundColor: AppColors.textPrimaryOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: AppColors.dividerOf(context))),
        title: Text(_title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
      ),
      body: Column(
        children: [
          // ── Status tabs (All / Open / Closed) ───────────────────────────
          Container(
            color: AppColors.surface(context),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              children: [
                _StatusTab(
                  label: 'All',
                  selected: filter.status == 'all',
                  onTap: () => _setStatus(ref, 'all'),
                ),
                const SizedBox(width: 10),
                _StatusTab(
                  label: _isEstimate ? 'Open Estimate' : 'Open Challan',
                  selected: filter.status == 'open',
                  onTap: () => _setStatus(ref, 'open'),
                ),
                const SizedBox(width: 10),
                _StatusTab(
                  label: _isEstimate ? 'Closed Estimate' : 'Closed Challan',
                  selected: filter.status == 'closed',
                  onTap: () => _setStatus(ref, 'closed'),
                ),
              ],
            ),
          ),

          // ── Search ───────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              decoration: InputDecoration(
                hintText: _searchHint,
                prefixIcon: const Icon(Icons.search, color: AppColors.primary),
                isDense: true,
                filled: true,
                fillColor: AppColors.surface(context),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.dividerOf(context)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: AppColors.dividerOf(context)),
                ),
              ),
              onChanged: (v) => ref.read(_filterProvider.notifier).state =
                  filter.copyWith(search: v),
            ),
          ),

          // ── List ─────────────────────────────────────────────────────────
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async => ref.refreshTransactions(),
              child: listAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) =>
                    ListView(children: [Center(child: Text('Error: $e'))]),
                data: (txns) {
                  if (txns.isEmpty) {
                    return ListView(
                      children: [
                        const SizedBox(height: 80),
                        Center(
                          child: Text(_emptyLabel,
                              style: const TextStyle(
                                  color: AppColors.textSecondary)),
                        ),
                      ],
                    );
                  }
                  return ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                    itemCount: txns.length,
                    itemBuilder: (_, i) => _DocCard(
                      key: ValueKey(txns[i].id),
                      txn: txns[i],
                      convertLabel: _convertLabel,
                      onTap: () => _open(context, ref, txns[i]),
                      onConvert: txns[i].status == 'active'
                          ? () => _convert(context, ref, txns[i].id!)
                          : null,
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
        label: Text(_addLabel,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        onPressed: () => _openCreate(context, ref),
      ),
    );
  }

  void _setStatus(WidgetRef ref, String status) {
    final cur = ref.read(_filterProvider);
    ref.read(_filterProvider.notifier).state = cur.copyWith(status: status);
  }

  Future<void> _openCreate(BuildContext context, WidgetRef ref) async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AddEditTransactionScreen(mode: _formMode),
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

  Future<void> _convert(BuildContext context, WidgetRef ref, int sourceId) async {
    final repo = ref.read(transactionRepositoryProvider);
    // The new sale's invoice number is minted atomically inside the conversion.
    final saleId = _isEstimate
        ? await repo.convertEstimateToSale(sourceId)
        : await repo.convertChallanToSale(sourceId);
    ref.refreshTransactions();
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SaleDetailScreen(transactionId: saleId),
      ),
    );
    ref.refreshTransactions();
  }
}

// ── Status tab chip ─────────────────────────────────────────────────────────

class _StatusTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _StatusTab(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.expense.withValues(alpha: 0.1)
              : AppColors.surface(context),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected ? AppColors.expense : AppColors.dividerOf(context),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? AppColors.expense : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ── Document card ───────────────────────────────────────────────────────────

class _DocCard extends StatelessWidget {
  final Transaction txn;
  final String convertLabel;
  final VoidCallback onTap;

  /// When null, the document is already converted (closed) — no convert action.
  final VoidCallback? onConvert;

  const _DocCard({
    super.key,
    required this.txn,
    required this.convertLabel,
    required this.onTap,
    required this.onConvert,
  });

  bool get _isOpen => txn.status == 'active';

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
              // Top row: party + status badge   |   number + date
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                txn.partyName?.isNotEmpty == true
                                    ? txn.partyName!
                                    : 'Cash',
                                style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _StatusBadge(isOpen: _isOpen),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          Formatters.currency(txn.totalAmount),
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.w700),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text('#${txn.transactionNumber}',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                      const SizedBox(height: 2),
                      Text(
                        Formatters.date(txn.transactionDate),
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // Bottom row: balance / due date  |  convert action
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          txn.dueDate != null && txn.dueDate!.isNotEmpty
                              ? 'Due Date: ${Formatters.date(txn.dueDate)}'
                              : 'Balance',
                          style: const TextStyle(
                              fontSize: 13, color: AppColors.textSecondary),
                        ),
                        if (txn.dueDate == null || txn.dueDate!.isEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            Formatters.currency(txn.balanceAmount),
                            style: const TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (onConvert != null)
                    TextButton(
                      onPressed: onConvert,
                      style: TextButton.styleFrom(
                        backgroundColor: AppColors.partial.withValues(alpha: 0.1),
                        foregroundColor: AppColors.partial,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                      ),
                      child: Text(convertLabel,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w600)),
                    )
                  else
                    const Text('Converted',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.paid)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final bool isOpen;
  const _StatusBadge({required this.isOpen});

  @override
  Widget build(BuildContext context) {
    final color = isOpen ? AppColors.pending : AppColors.paid;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        isOpen ? 'OPEN' : 'CLOSED',
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}
