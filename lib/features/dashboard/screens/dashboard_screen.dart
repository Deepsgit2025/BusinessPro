import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/providers/business_provider.dart';
import '../../../core/utils/formatters.dart';
import '../../items/screens/add_edit_item_screen.dart';
import '../../transactions/models/transaction.dart';
import '../../transactions/providers/transaction_providers.dart';
import '../../transactions/screens/sale_detail_screen.dart';
import '../../transactions/screens/sale_list_screen.dart';
import '../../transactions/services/document_actions.dart';
import '../../transactions/widgets/transaction_card.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Refresh the outstanding totals on first mount (a peer device may have
    // synced new transactions in while the dashboard wasn't the active tab).
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshOutstanding());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-pull the To Collect / To Pay figures whenever the app comes back to
    // the foreground — sync may have changed balances while backgrounded.
    if (state == AppLifecycleState.resumed) _refreshOutstanding();
  }

  void _refreshOutstanding() {
    ref.invalidate(outstandingReceivablesProvider);
    ref.invalidate(outstandingPayablesProvider);
  }

  @override
  Widget build(BuildContext context) {
    final bizAsync = ref.watch(businessProvider);

    return bizAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (biz) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          _SummaryRow(),
          const SizedBox(height: 22),
          _QuickActions(),
          const SizedBox(height: 22),
          _RecentTransactions(),
        ],
      ),
    );
  }
}

class _SummaryRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final receivables = ref.watch(outstandingReceivablesProvider);
    final payables = ref.watch(outstandingPayablesProvider);

    // Null/loading/error all fall back to ₹0 so the cards never show a spinner
    // or blank in place of a number.
    String money(AsyncValue<double> v) =>
        Formatters.currency(v.valueOrNull ?? 0);

    return Row(
      children: [
        Expanded(
          child: _SummaryCard(
            label: 'To Collect',
            amount: money(receivables),
            icon: Icons.south_west_rounded,
            gradient: AppColors.incomeGradient,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: _SummaryCard(
            label: 'To Pay',
            amount: money(payables),
            icon: Icons.north_east_rounded,
            gradient: AppColors.expenseGradient,
          ),
        ),
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String amount;
  final IconData icon;
  final Gradient gradient;

  const _SummaryCard({
    required this.label,
    required this.amount,
    required this.icon,
    required this.gradient,
  });

  @override
  Widget build(BuildContext context) {
    final tint = (gradient as LinearGradient).colors.first;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: gradient,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: tint.withValues(alpha: 0.30),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.22),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(height: 14),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.9),
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            amount,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Quick Actions'),
        const SizedBox(height: 14),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _ActionChip(
              icon: Icons.receipt_long,
              label: 'Sale',
              color: AppColors.primary,
              onTap: () => SaleListScreen.openCreateSheet(context, ref),
            ),
            _ActionChip(
              icon: Icons.add_box_outlined,
              label: 'Add Item',
              color: AppColors.pending,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AddEditItemScreen()),
              ),
            ),
            _ActionChip(
              icon: Icons.money_off,
              label: 'Expense',
              color: AppColors.expense,
              onTap: () => Navigator.pushNamed(context, '/expense'),
            ),
            _ActionChip(
              icon: Icons.groups_2,
              label: 'Employees',
              color: AppColors.partial,
              onTap: () => Navigator.pushNamed(context, '/employees'),
            ),
          ],
        ),
      ],
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.color,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          children: [
            Container(
              height: 56,
              width: 56,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 18,
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _RecentTransactions extends ConsumerWidget {
  /// Routes a tapped recent-transaction card to its detail screen, mirroring
  /// the list screens: sale/purchase (and every billed document type) open the
  /// shared [SaleDetailScreen]. Cash transactions (expense / other_income) have
  /// no dedicated detail screen anywhere in the app, so they fall back to their
  /// respective list screen — the same surface that creates them.
  Future<void> _openTransaction(
      BuildContext context, WidgetRef ref, Transaction txn) async {
    switch (txn.transactionType) {
      case TxnTypes.expense:
        await Navigator.pushNamed(context, '/expense');
      case TxnTypes.otherIncome:
        await Navigator.pushNamed(context, '/income');
      default:
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SaleDetailScreen(transactionId: txn.id!),
          ),
        );
    }
    // Sync or an edit on the detail screen may have changed balances; refresh
    // the recent list and the To Collect / To Pay totals, as the list screens do.
    ref.refreshTransactions();
    ref.invalidate(outstandingReceivablesProvider);
    ref.invalidate(outstandingPayablesProvider);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncTxns = ref.watch(recentTransactionsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader('Recent Transactions'),
        const SizedBox(height: 14),
        asyncTxns.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('Error: $e')),
          data: (txns) {
            if (txns.isEmpty) {
              return Card(
                child: Padding(
                  padding: const EdgeInsets.all(36),
                  child: Center(
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: AppColors.primary.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.receipt_long_outlined,
                              size: 40, color: AppColors.primary),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'No transactions yet',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Your recent sales & purchases will appear here',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.textHint,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }
            return Column(
              children: txns
                  .map((txn) => TransactionCard(
                        // Stable identity per transaction so a card Element is
                        // matched to its data (and routes to the right id) after
                        // the list refreshes — same reason the list screens key
                        // their cards.
                        key: ValueKey(txn.id),
                        txn: txn,
                        onTap: () => _openTransaction(context, ref, txn),
                        // Auto-hidden for the expense / income rows (no PDF) by
                        // the card's own PDF-able gate.
                        onPrint: () =>
                            DocumentActions.printById(context, ref, txn),
                        onShare: () =>
                            DocumentActions.shareById(context, ref, txn),
                      ))
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}
