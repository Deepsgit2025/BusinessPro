import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../transactions/screens/sale_detail_screen.dart';
import '../providers/account_providers.dart';

/// Running-balance ledger for one account, filterable by period.
class AccountStatementScreen extends ConsumerStatefulWidget {
  final int accountId;
  const AccountStatementScreen({super.key, required this.accountId});

  @override
  ConsumerState<AccountStatementScreen> createState() =>
      _AccountStatementScreenState();
}

enum _Period { thisMonth, thisYear, all }

class _AccountStatementScreenState
    extends ConsumerState<AccountStatementScreen> {
  _Period _period = _Period.thisMonth;

  StatementArgs get _args {
    final now = DateTime.now();
    switch (_period) {
      case _Period.thisMonth:
        final from = DateTime(now.year, now.month, 1);
        return StatementArgs(widget.accountId,
            fromDate: from.toIso8601String());
      case _Period.thisYear:
        final from = DateTime(now.year, 1, 1);
        return StatementArgs(widget.accountId,
            fromDate: from.toIso8601String());
      case _Period.all:
        return StatementArgs(widget.accountId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountAsync = ref.watch(accountDetailProvider(widget.accountId));
    final statementAsync = ref.watch(accountStatementProvider(_args));

    return Scaffold(
      appBar: AppBar(
        title: accountAsync.maybeWhen(
          data: (a) => Text(a?.name ?? 'Statement'),
          orElse: () => const Text('Statement'),
        ),
      ),
      body: Column(
        children: [
          accountAsync.maybeWhen(
            data: (a) => a == null
                ? const SizedBox.shrink()
                : Container(
                    width: double.infinity,
                    color: AppColors.primary.withValues(alpha: 0.07),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Current Balance',
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textSecondary)),
                        const SizedBox(height: 2),
                        Text(Formatters.currency(a.currentBalance),
                            style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: AppColors.primary)),
                      ],
                    ),
                  ),
            orElse: () => const SizedBox.shrink(),
          ),
          _PeriodTabs(
            selected: _period,
            onChanged: (p) => setState(() => _period = p),
          ),
          Expanded(
            child: statementAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (rows) {
                final opening = accountAsync.valueOrNull?.openingBalance ?? 0;
                if (rows.isEmpty) {
                  return _EmptyLedger(opening: opening);
                }
                // Newest first for display; ledger was built oldest→newest so we
                // reverse but keep each row's running balance.
                final display = rows.reversed.toList();
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: display.length + 1,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i == display.length) {
                      return _OpeningRow(opening: opening);
                    }
                    return _LedgerRow(row: display[i]);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _PeriodTabs extends StatelessWidget {
  final _Period selected;
  final ValueChanged<_Period> onChanged;
  const _PeriodTabs({required this.selected, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _chip('This Month', _Period.thisMonth),
          const SizedBox(width: 8),
          _chip('This Year', _Period.thisYear),
          const SizedBox(width: 8),
          _chip('All', _Period.all),
        ],
      ),
    );
  }

  Widget _chip(String label, _Period p) => ChoiceChip(
        label: Text(label),
        selected: selected == p,
        onSelected: (_) => onChanged(p),
      );
}

class _LedgerRow extends StatelessWidget {
  final Map<String, dynamic> row;
  const _LedgerRow({required this.row});

  @override
  Widget build(BuildContext context) {
    final moneyIn = (row['money_in'] as num).toDouble();
    final moneyOut = (row['money_out'] as num).toDouble();
    final running = (row['running_balance'] as num).toDouble();
    final isIn = moneyIn > 0;
    final party = row['party_name'] as String?;
    final number = row['transaction_number'] as String? ?? '';
    final txnId = row['transaction_id'] as int?;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      title: Text(party?.isNotEmpty == true ? party! : number,
          style: const TextStyle(fontWeight: FontWeight.w500)),
      subtitle: Text(
        '${Formatters.date(row['transaction_date'] as String?)} · $number',
        style: const TextStyle(fontSize: 11),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${isIn ? '+' : '-'}${Formatters.currency(isIn ? moneyIn : moneyOut)}',
            style: TextStyle(
              color: isIn ? AppColors.income : AppColors.expense,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(Formatters.currency(running),
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textSecondary)),
        ],
      ),
      onTap: txnId == null
          ? null
          : () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SaleDetailScreen(transactionId: txnId),
                ),
              ),
    );
  }
}

class _OpeningRow extends StatelessWidget {
  final double opening;
  const _OpeningRow({required this.opening});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      title: const Text('Opening Balance',
          style: TextStyle(fontStyle: FontStyle.italic)),
      trailing: Text(Formatters.currency(opening),
          style: const TextStyle(
              fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
    );
  }
}

class _EmptyLedger extends StatelessWidget {
  final double opening;
  const _EmptyLedger({required this.opening});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        _OpeningRow(opening: opening),
        const Divider(height: 1),
        const Padding(
          padding: EdgeInsets.all(32),
          child: Center(
            child: Text('No transactions in this period',
                style: TextStyle(color: AppColors.textSecondary)),
          ),
        ),
      ],
    );
  }
}
