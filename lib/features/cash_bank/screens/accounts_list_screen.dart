import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/account.dart';
import '../providers/account_providers.dart';
import 'account_statement_screen.dart';
import 'add_account_screen.dart';
import 'money_transfer_screen.dart';

/// Cash & Bank home (drawer → Cash & Bank). Lists accounts with balances, a
/// total-balance header, a "Transfer Money" action, and a FAB to add accounts.
class AccountsListScreen extends ConsumerWidget {
  const AccountsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountsAsync = ref.watch(accountListProvider);
    final totalAsync = ref.watch(totalBalanceProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cash & Bank'),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Transfer Money',
            onPressed: () async {
              final r = await Navigator.push<bool>(
                context,
                MaterialPageRoute(builder: (_) => const MoneyTransferScreen()),
              );
              if (r == true) {
                ref.invalidate(accountListProvider);
                ref.invalidate(totalBalanceProvider);
              }
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppColors.primary,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Add Account', style: TextStyle(color: Colors.white)),
        onPressed: () async {
          final r = await Navigator.push<bool>(
            context,
            MaterialPageRoute(builder: (_) => const AddAccountScreen()),
          );
          if (r == true) {
            ref.invalidate(accountListProvider);
            ref.invalidate(totalBalanceProvider);
          }
        },
      ),
      body: accountsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (accounts) => Column(
          children: [
            totalAsync.maybeWhen(
              data: (total) => _TotalHeader(total: total),
              orElse: () => const SizedBox(height: 4),
            ),
            Expanded(
              child: accounts.isEmpty
                  ? const _EmptyState()
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: accounts.length,
                      itemBuilder: (context, i) => _AccountCard(
                        account: accounts[i],
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => AccountStatementScreen(
                                accountId: accounts[i].id!),
                          ),
                        ),
                        onEdit: () async {
                          final r = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  AddAccountScreen(account: accounts[i]),
                            ),
                          );
                          if (r == true) {
                            ref.invalidate(accountListProvider);
                            ref.invalidate(totalBalanceProvider);
                          }
                        },
                        onDelete: () =>
                            _confirmDelete(context, ref, accounts[i], accounts),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalHeader extends StatelessWidget {
  final double total;
  const _TotalHeader({required this.total});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.primary.withValues(alpha: 0.07),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Total Balance',
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(Formatters.currency(total),
              style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primary)),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final Account account;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  const _AccountCard({
    required this.account,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final (icon, label) = switch (account.accountType) {
      'bank' => (Icons.account_balance, 'Bank'),
      'wallet' => (Icons.account_balance_wallet, 'Wallet'),
      _ => (Icons.payments, 'Cash'),
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                child: Icon(icon, color: AppColors.primary, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(account.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis),
                        ),
                        if (account.isDefault) ...[
                          const SizedBox(width: 6),
                          _Tag('Default', AppColors.primary),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      account.bankName?.isNotEmpty == true
                          ? '$label · ${account.bankName}'
                          : label,
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Text(
                Formatters.currency(account.currentBalance),
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 15,
                  color: account.currentBalance < 0
                      ? AppColors.expense
                      : AppColors.textPrimary,
                ),
              ),
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert,
                    size: 20, color: AppColors.textSecondary),
                onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit')),
                  PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Soft-deletes an account after confirmation. Blocks removing the last cash
/// account so the "exactly one cash account" rule always holds.
Future<void> _confirmDelete(
  BuildContext context,
  WidgetRef ref,
  Account account,
  List<Account> all,
) async {
  if (account.accountType == 'cash' &&
      all.where((a) => a.accountType == 'cash').length <= 1) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('You must keep one cash account.')),
    );
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Delete account?'),
      content: Text('Remove "${account.name}"? Its past entries stay, but the '
          'account will no longer appear here.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel')),
        TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  await ref.read(accountRepoProvider).softDelete(account.id!);
  ref.invalidate(accountListProvider);
  ref.invalidate(totalBalanceProvider);
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;
  const _Tag(this.label, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label,
          style:
              TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w600)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.account_balance_wallet_outlined,
              size: 64, color: AppColors.textHint),
          SizedBox(height: 12),
          Text('No accounts yet',
              style: TextStyle(color: AppColors.textSecondary)),
          SizedBox(height: 8),
          Text('Tap + to add a cash or bank account',
              style: TextStyle(color: AppColors.textHint, fontSize: 12)),
        ],
      ),
    );
  }
}
