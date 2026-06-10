import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/account.dart';
import '../repositories/account_repository.dart';

final accountRepoProvider = Provider<AccountRepository>((ref) => AccountRepository());

final accountListProvider = FutureProvider<List<Account>>((ref) async {
  return ref.watch(accountRepoProvider).getAccounts();
});

final totalBalanceProvider = FutureProvider<double>((ref) async {
  ref.watch(accountListProvider);
  return ref.watch(accountRepoProvider).totalBalance();
});

final accountDetailProvider =
    FutureProvider.family<Account?, int>((ref, id) async {
  return ref.watch(accountRepoProvider).getById(id);
});

/// Statement (running-balance ledger) for an account over an optional range.
class StatementArgs {
  final int accountId;
  final String? fromDate;
  final String? toDate;
  const StatementArgs(this.accountId, {this.fromDate, this.toDate});

  @override
  bool operator ==(Object other) =>
      other is StatementArgs &&
      other.accountId == accountId &&
      other.fromDate == fromDate &&
      other.toDate == toDate;

  @override
  int get hashCode => Object.hash(accountId, fromDate, toDate);
}

final accountStatementProvider =
    FutureProvider.family<List<Map<String, dynamic>>, StatementArgs>((ref, args) async {
  return ref.watch(accountRepoProvider).statement(
        args.accountId,
        fromDate: args.fromDate,
        toDate: args.toDate,
      );
});
