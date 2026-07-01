import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../transactions/screens/sale_detail_screen.dart';
import '../models/party.dart';
import '../providers/party_providers.dart';
import 'add_edit_party_screen.dart';

/// Read-only view of a single party with Transactions + Statement tabs.
class PartyDetailScreen extends ConsumerWidget {
  final int partyId;
  const PartyDetailScreen({super.key, required this.partyId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final partyAsync = ref.watch(partyDetailProvider(partyId));

    return partyAsync.when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(),
        body: Center(child: Text('Error: $e')),
      ),
      data: (party) {
        if (party == null) {
          return Scaffold(
            appBar: AppBar(),
            body: const Center(child: Text('Party not found')),
          );
        }
        return _PartyDetailView(party: party);
      },
    );
  }
}

class _PartyDetailView extends ConsumerWidget {
  final Party party;
  const _PartyDetailView({required this.party});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balance = party.netBalance;
    final balanceColor = party.isSettled
        ? AppColors.textSecondary
        : (balance >= 0 ? AppColors.income : AppColors.expense);

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(party.name),
          actions: [
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => AddEditPartyScreen(party: party)),
                );
                ref.invalidate(partyDetailProvider(party.id!));
                ref.invalidate(partyTransactionsProvider(party.id!));
                if (result == 'deleted' && context.mounted) {
                  Navigator.pop(context); // close detail too
                }
              },
            ),
          ],
          bottom: const TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: Colors.white,
            tabs: [Tab(text: 'Transactions'), Tab(text: 'Statement')],
          ),
        ),
        body: Column(
          children: [
            _HeaderCard(party: party, balance: balance, balanceColor: balanceColor),
            Expanded(
              child: TabBarView(
                children: [
                  _TransactionsTab(partyId: party.id!),
                  _StatementTab(party: party),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final Party party;
  final double balance;
  final Color balanceColor;
  const _HeaderCard({
    required this.party,
    required this.balance,
    required this.balanceColor,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(party.name,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold)),
                      if (party.phone != null && party.phone!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(party.phone!,
                              style: const TextStyle(
                                  color: AppColors.textSecondary, fontSize: 13)),
                        ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(Formatters.currency(balance.abs()),
                        style: TextStyle(
                            color: balanceColor,
                            fontSize: 18,
                            fontWeight: FontWeight.bold)),
                    Text(party.balanceLabel,
                        style: TextStyle(color: balanceColor, fontSize: 12)),
                  ],
                ),
              ],
            ),
            const Divider(height: 24),
            if (party.email != null && party.email!.isNotEmpty)
              _info(Icons.email_outlined, party.email!),
            if (party.gstin != null && party.gstin!.isNotEmpty)
              _info(Icons.badge_outlined, 'GSTIN: ${party.gstin}'),
            if (_addressLine(party).isNotEmpty)
              _info(Icons.location_on_outlined, _addressLine(party)),
            if (party.creditLimit > 0)
              _info(Icons.credit_card_outlined,
                  'Credit limit: ${Formatters.currency(party.creditLimit)}'),
            if (party.creditDays > 0)
              _info(Icons.calendar_today_outlined,
                  'Credit days: ${party.creditDays}'),
          ],
        ),
      ),
    );
  }

  static String _addressLine(Party p) {
    final parts = [
      p.billingAddress,
      p.billingCity,
      p.billingState,
      p.billingPincode,
    ].where((e) => e != null && e.trim().isNotEmpty).toList();
    return parts.join(', ');
  }

  Widget _info(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 16, color: AppColors.textSecondary),
            const SizedBox(width: 8),
            Expanded(
                child: Text(text,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.textSecondary))),
          ],
        ),
      );
}

class _TransactionsTab extends ConsumerWidget {
  final int partyId;
  const _TransactionsTab({required this.partyId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txnsAsync = ref.watch(partyTransactionsProvider(partyId));
    return txnsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (txns) {
        if (txns.isEmpty) {
          return const Center(
            child: Text('No transactions with this party yet',
                style: TextStyle(color: AppColors.textSecondary)),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          itemCount: txns.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final t = txns[i];
            final type = (t['transaction_type'] as String?) ?? '';
            final total = (t['total_amount'] as num?)?.toDouble() ?? 0;
            final bal = (t['balance_amount'] as num?)?.toDouble() ?? 0;
            final id = t['id'] as int?;
            return ListTile(
              dense: true,
              onTap: id == null
                  ? null
                  : () async {
                      await Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) =>
                              SaleDetailScreen(transactionId: id),
                        ),
                      );
                      // Balances / lists may have changed (edit, payment,
                      // delete) — refresh this party's views on return.
                      ref.invalidate(partyDetailProvider(partyId));
                      ref.invalidate(partyTransactionsProvider(partyId));
                    },
              title: Text(t['transaction_number']?.toString() ??
                  _typeLabel(type)),
              subtitle: Text(
                  '${_typeLabel(type)} • ${Formatters.date(t['transaction_date'] as String?)}'),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(Formatters.currency(total),
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  if (bal != 0)
                    Text('Bal ${Formatters.currency(bal)}',
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.expense)),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _StatementTab extends ConsumerWidget {
  final Party party;
  const _StatementTab({required this.party});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ledgerAsync = ref.watch(partyLedgerProvider(party.id!));
    return ledgerAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Error: $e')),
      data: (events) {
        // Opening balance row, then a running ledger folded from the double-entry
        // events (bills at full total + real payments), oldest → newest.
        double running = party.openingBalanceType == 'debit'
            ? party.openingBalance
            : -party.openingBalance;

        final rows = <_LedgerRow>[
          _LedgerRow(
            date: '',
            description: 'Opening Balance',
            debit: running > 0 ? running : 0,
            credit: running < 0 ? -running : 0,
            balance: running,
          ),
        ];

        for (final e in events) {
          final type = (e['transaction_type'] as String?) ?? '';
          final kind = (e['kind'] as String?) ?? 'bill';
          final debit = (e['debit'] as num?)?.toDouble() ?? 0;
          final credit = (e['credit'] as num?)?.toDouble() ?? 0;
          // Debit raises To Collect, credit raises To Pay.
          running += debit - credit;
          final number = e['description']?.toString() ?? _typeLabel(type);
          rows.add(_LedgerRow(
            date: Formatters.date(e['date'] as String?),
            // Distinguish a payment against a bill from the bill itself.
            description: kind == 'payment'
                ? '$number · ${_paymentLabel(type)}'
                : number,
            debit: debit,
            credit: credit,
            balance: running,
          ));
        }

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            const _LedgerHeader(),
            const Divider(height: 8),
            ...rows.map((r) => _LedgerTile(row: r)),
          ],
        );
      },
    );
  }
}

/// Short caption for a payment ledger row, by the underlying document type.
String _paymentLabel(String type) => switch (type) {
      'payment_in' => 'Payment In',
      'payment_out' => 'Payment Out',
      _ => 'Paid',
    };

class _LedgerRow {
  final String date;
  final String description;
  final double debit;
  final double credit;
  final double balance;
  const _LedgerRow({
    required this.date,
    required this.description,
    required this.debit,
    required this.credit,
    required this.balance,
  });
}

class _LedgerHeader extends StatelessWidget {
  const _LedgerHeader();
  @override
  Widget build(BuildContext context) {
    const style = TextStyle(
        fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary);
    return Row(
      children: const [
        Expanded(flex: 3, child: Text('Description', style: style)),
        Expanded(flex: 2, child: Text('Debit', style: style, textAlign: TextAlign.end)),
        Expanded(flex: 2, child: Text('Credit', style: style, textAlign: TextAlign.end)),
        Expanded(flex: 2, child: Text('Balance', style: style, textAlign: TextAlign.end)),
      ],
    );
  }
}

class _LedgerTile extends StatelessWidget {
  final _LedgerRow row;
  const _LedgerTile({required this.row});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(row.description,
                    style: const TextStyle(fontSize: 12),
                    overflow: TextOverflow.ellipsis),
                if (row.date.isNotEmpty)
                  Text(row.date,
                      style: const TextStyle(
                          fontSize: 10, color: AppColors.textHint)),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(row.debit == 0 ? '—' : Formatters.currency(row.debit),
                textAlign: TextAlign.end, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            flex: 2,
            child: Text(row.credit == 0 ? '—' : Formatters.currency(row.credit),
                textAlign: TextAlign.end, style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            flex: 2,
            child: Text(Formatters.currency(row.balance.abs()),
                textAlign: TextAlign.end,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: row.balance >= 0
                        ? AppColors.income
                        : AppColors.expense)),
          ),
        ],
      ),
    );
  }
}

String _typeLabel(String type) => switch (type) {
      'sale' => 'Sale',
      'sale_return' => 'Sale Return',
      'purchase' => 'Purchase',
      'purchase_return' => 'Purchase Return',
      'payment_in' => 'Payment In',
      'payment_out' => 'Payment Out',
      'estimate' => 'Estimate',
      'expense' => 'Expense',
      'other_income' => 'Income',
      _ => type,
    };
