import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../models/transaction.dart';
import '../providers/transaction_providers.dart';
import '../widgets/transaction_card.dart';
import 'add_edit_transaction_screen.dart';
import 'add_payment_in_screen.dart';
import 'all_transactions_screen.dart';
import 'doc_list_screen.dart';
import 'sale_detail_screen.dart';
import 'sale_return_list_screen.dart';

class SaleListScreen extends ConsumerWidget {
  const SaleListScreen({super.key});

  // Keep this so the shell FAB can still open the Sale Invoice form directly.
  static Future<void> openCreateSheet(BuildContext context, WidgetRef ref) async {
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => const AddEditTransactionScreen(mode: TxnFormMode.sale),
      ),
    );
    if (created == true) ref.refreshTransactions();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recentAsync = ref.watch(saleRecentProvider);

    return RefreshIndicator(
      onRefresh: () async => ref.refreshTransactions(),
      child: CustomScrollView(
        slivers: [
          // ── 6 action buttons ────────────────────────────────────────────
          SliverToBoxAdapter(
            child: _ActionGrid(
              onTap: (mode) => _openCreate(context, ref, mode),
            ),
          ),

          // ── "Recent Transactions" header ────────────────────────────────
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 6),
              child: Text(
                'Recent Transactions',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),

          // ── Recent list ─────────────────────────────────────────────────
          recentAsync.when(
            loading: () => const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => SliverFillRemaining(
              child: Center(child: Text('Error: $e')),
            ),
            data: (txns) {
              if (txns.isEmpty) {
                return const SliverFillRemaining(
                  child: _EmptyState(),
                );
              }
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                sliver: SliverList.builder(
                  itemCount: txns.length,
                  itemBuilder: (context, i) {
                    final txn = txns[i];
                    return TransactionCard(
                      // Stable identity per transaction so Flutter matches each
                      // card Element to its data after the list refreshes (e.g.
                      // right after a save). Without it, keyless cards are reused
                      // by index and a tap can route to the previously-shown
                      // transaction's id.
                      key: ValueKey(txn.id),
                      txn: txn,
                      onTap: () => _open(context, ref, txn),
                      onLongPress: () => _longPressMenu(context, ref, txn),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _openCreate(
      BuildContext context, WidgetRef ref, TxnFormMode mode) async {
    // "Sale Return" opens its own Credit Note list (with a FAB to add one),
    // not the entry form directly.
    final Widget screen = switch (mode) {
      // Payment-In opens its own filterable list (date / period / party),
      // with an "Add Payment-In" button that opens the entry form.
      TxnFormMode.paymentIn => AllTransactionsScreen(
          lockedTxnType: TxnTypes.paymentIn,
          title: 'Payment-In',
          addLabel: 'Add Payment-In',
          onAdd: (ctx) => Navigator.push<bool>(
            ctx,
            MaterialPageRoute(builder: (_) => const AddPaymentInScreen()),
          ),
        ),
      TxnFormMode.saleReturn => const SaleReturnListScreen(),
      // Estimate and Delivery Challan open their own list screens (with status
      // tabs, search, an inline Convert action and an Add FAB) rather than the
      // entry form directly.
      TxnFormMode.estimate => const DocListScreen(kind: DocKind.estimate),
      TxnFormMode.deliveryChallan =>
        const DocListScreen(kind: DocKind.deliveryChallan),
      _ => AddEditTransactionScreen(mode: mode),
    };
    final created = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => screen),
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

  Future<void> _longPressMenu(
      BuildContext context, WidgetRef ref, Transaction txn) async {
    final isEstimate = txn.transactionType == TxnTypes.estimate;
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('Open'),
              onTap: () {
                Navigator.pop(context);
                _open(context, ref, txn);
              },
            ),
            if (!isEstimate && !txn.isCancelled)
              ListTile(
                leading: const Icon(Icons.cancel_outlined,
                    color: AppColors.expense),
                title: const Text('Cancel'),
                onTap: () async {
                  Navigator.pop(context);
                  await ref
                      .read(transactionRepositoryProvider)
                      .cancel(txn.id!);
                  ref.refreshTransactions();
                },
              ),
            ListTile(
              leading:
                  const Icon(Icons.delete_outline, color: AppColors.expense),
              title: const Text('Delete'),
              onTap: () async {
                Navigator.pop(context);
                await ref
                    .read(transactionRepositoryProvider)
                    .softDelete(txn.id!);
                ref.refreshTransactions();
              },
            ),
          ],
        ),
      ),
    );
  }
}

// ── 6-button action grid ───────────────────────────────────────────────────────

class _ActionGrid extends StatelessWidget {
  final void Function(TxnFormMode) onTap;
  const _ActionGrid({required this.onTap});

  static const _items = [
    _ActionItem(
      label: 'Sale Invoice',
      icon: Icons.receipt_long,
      color: Color(0xFF2E7D32),
      mode: TxnFormMode.sale,
    ),
    _ActionItem(
      label: 'Payment-In',
      icon: Icons.payments_outlined,
      color: Color(0xFF1565C0),
      mode: TxnFormMode.paymentIn,
    ),
    _ActionItem(
      label: 'Sale Return',
      icon: Icons.assignment_return_outlined,
      color: Color(0xFFD32F2F),
      mode: TxnFormMode.saleReturn,
    ),
    _ActionItem(
      label: 'Estimate/\nQuotation',
      icon: Icons.description_outlined,
      color: Color(0xFFF57F17),
      mode: TxnFormMode.estimate,
    ),
    _ActionItem(
      label: 'Sale Order',
      icon: Icons.shopping_bag_outlined,
      color: Color(0xFF6A1B9A),
      mode: TxnFormMode.saleOrder,
    ),
    _ActionItem(
      label: 'Delivery\nChallan',
      icon: Icons.local_shipping_outlined,
      color: Color(0xFF00838F),
      mode: TxnFormMode.deliveryChallan,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface(context),
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
      // 3 buttons per row. A fixed row height (mainAxisExtent) keeps the two
      // rows tight together — using childAspectRatio instead would stretch the
      // cells tall on wide (desktop) windows and leave an ugly gap between rows.
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisExtent: 96,
          mainAxisSpacing: 4,
        ),
        itemCount: _items.length,
        itemBuilder: (context, i) =>
            _ActionButton(item: _items[i], onTap: () => onTap(_items[i].mode)),
      ),
    );
  }
}

class _ActionItem {
  final String label;
  final IconData icon;
  final Color color;
  final TxnFormMode mode;
  const _ActionItem({
    required this.label,
    required this.icon,
    required this.color,
    required this.mode,
  });
}

class _ActionButton extends StatelessWidget {
  final _ActionItem item;
  final VoidCallback onTap;
  const _ActionButton({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                color: item.color.withValues(alpha: 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(item.icon, color: item.color, size: 24),
            ),
            const SizedBox(height: 6),
            Text(
              item.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimaryOf(context),
                height: 1.3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Empty state ────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined,
              size: 64, color: AppColors.textHint),
          SizedBox(height: 12),
          Text('No transactions yet',
              style: TextStyle(color: AppColors.textSecondary)),
          SizedBox(height: 8),
          Text('Tap a button above to get started',
              style: TextStyle(color: AppColors.textHint, fontSize: 12)),
        ],
      ),
    );
  }
}

