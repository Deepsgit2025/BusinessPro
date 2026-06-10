import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../models/party.dart';
import '../providers/party_providers.dart';
import '../widgets/party_card.dart';
import 'add_edit_party_screen.dart';
import 'party_detail_screen.dart';

/// Parties list — lives inside MainShell's IndexedStack (the shell provides the
/// "Parties" AppBar). Owns its own filter tabs, search bar and FAB.
class PartiesScreen extends ConsumerStatefulWidget {
  const PartiesScreen({super.key});

  @override
  ConsumerState<PartiesScreen> createState() => _PartiesScreenState();
}

class _PartiesScreenState extends ConsumerState<PartiesScreen> {
  final _searchCtrl = TextEditingController();

  static const _tabs = ['all', 'customer', 'supplier'];
  static const _tabLabels = ['All', 'Customers', 'Suppliers'];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openAdd() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddEditPartyScreen()),
    );
  }

  void _openDetail(Party party) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => PartyDetailScreen(partyId: party.id!)),
    );
  }

  void _openEdit(Party party) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddEditPartyScreen(party: party)),
    );
  }

  Future<void> _confirmDelete(Party party) async {
    final repo = ref.read(partyRepositoryProvider);
    final txnCount = await repo.transactionCount(party.id!);
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${party.name}?'),
        content: Text(
          txnCount > 0
              ? 'This party has $txnCount transaction(s). Deleting will not '
                  'remove those transactions.\n\nThis cannot be undone.'
              : 'This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.expense),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok == true) {
      await repo.softDelete(party.id!);
      ref.invalidate(partyListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${party.name} deleted')),
        );
      }
    }
  }

  void _showOptions(Party party) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: AppColors.primary),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(ctx);
                _openEdit(party);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.expense),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(party);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(partyFilterProvider);
    final partiesAsync = ref.watch(partyListProvider);
    final selectedTab = _tabs.indexOf(filter.type);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        onPressed: _openAdd,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: Column(
        children: [
          // Filter tabs
          Material(
            color: AppColors.primary,
            child: Row(
              children: List.generate(_tabs.length, (i) {
                final selected = i == selectedTab;
                return Expanded(
                  child: InkWell(
                    onTap: () => ref.read(partyFilterProvider.notifier).update(
                          (s) => s.copyWith(type: _tabs[i]),
                        ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: selected ? Colors.white : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                      ),
                      child: Text(
                        _tabLabels[i],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: selected ? Colors.white : Colors.white70,
                          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),

          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => ref
                  .read(partyFilterProvider.notifier)
                  .update((s) => s.copyWith(search: v)),
              decoration: InputDecoration(
                hintText: 'Search by name or phone',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          ref
                              .read(partyFilterProvider.notifier)
                              .update((s) => s.copyWith(search: ''));
                        },
                      ),
                isDense: true,
              ),
            ),
          ),

          // List
          Expanded(
            child: partiesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (parties) {
                if (parties.isEmpty) {
                  final searching = filter.search.isNotEmpty;
                  return _EmptyParties(
                    searching: searching,
                    onAdd: _openAdd,
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                  itemCount: parties.length,
                  itemBuilder: (_, i) {
                    final party = parties[i];
                    return PartyCard(
                      party: party,
                      onTap: () => _openDetail(party),
                      onLongPress: () => _showOptions(party),
                    );
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

class _EmptyParties extends StatelessWidget {
  final bool searching;
  final VoidCallback onAdd;
  const _EmptyParties({required this.searching, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    if (searching) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: AppColors.textHint),
            SizedBox(height: 12),
            Text('No parties match your search',
                style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.people_outline, size: 64, color: AppColors.textHint),
          const SizedBox(height: 16),
          const Text('No parties added yet',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add Party'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.primary,
              side: const BorderSide(color: AppColors.primary),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }
}
