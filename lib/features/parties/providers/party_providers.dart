import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/party.dart';
import '../repositories/party_repository.dart';

final partyRepositoryProvider = Provider<PartyRepository>((ref) => PartyRepository());

/// Current list filters. type: 'all' | 'customer' | 'supplier'.
class PartyFilter {
  final String type;
  final String search;
  const PartyFilter({this.type = 'all', this.search = ''});

  PartyFilter copyWith({String? type, String? search}) =>
      PartyFilter(type: type ?? this.type, search: search ?? this.search);
}

final partyFilterProvider =
    StateProvider<PartyFilter>((ref) => const PartyFilter());

/// The filtered list of parties, recomputed whenever the filter changes.
final partyListProvider = FutureProvider<List<Party>>((ref) async {
  final filter = ref.watch(partyFilterProvider);
  final repo = ref.watch(partyRepositoryProvider);
  return repo.getParties(
    type: filter.type == 'all' ? null : filter.type,
    search: filter.search,
  );
});

/// A single party (with fresh balance aggregates) by id.
final partyDetailProvider =
    FutureProvider.family<Party?, int>((ref, id) async {
  final repo = ref.watch(partyRepositoryProvider);
  return repo.getById(id);
});

final partyTransactionsProvider =
    FutureProvider.family<List<Map<String, dynamic>>, int>((ref, id) async {
  final repo = ref.watch(partyRepositoryProvider);
  return repo.transactions(id);
});

/// Double-entry ledger events (bills + real payments) for the Statement tab.
final partyLedgerProvider =
    FutureProvider.family<List<Map<String, dynamic>>, int>((ref, id) async {
  final repo = ref.watch(partyRepositoryProvider);
  return repo.ledger(id);
});
