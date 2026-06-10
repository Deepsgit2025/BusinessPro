import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../parties/models/party.dart';
import '../../parties/providers/party_providers.dart';
import '../../parties/repositories/party_repository.dart';
import '../../parties/screens/add_edit_party_screen.dart';

/// Searchable party picker bottom sheet. [type] restricts to 'customer' or
/// 'supplier' (a 'both' party matches either). Returns the chosen [Party], or
/// null if dismissed. Includes a "+ New Party" shortcut.
Future<Party?> showPartyPicker(BuildContext context, {required String type}) {
  return showModalBottomSheet<Party>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PartyPickerSheet(type: type),
  );
}

class _PartyPickerSheet extends ConsumerStatefulWidget {
  final String type;
  const _PartyPickerSheet({required this.type});

  @override
  ConsumerState<_PartyPickerSheet> createState() => _PartyPickerSheetState();
}

class _PartyPickerSheetState extends ConsumerState<_PartyPickerSheet> {
  final _repo = PartyRepository();
  String _search = '';
  late Future<List<Party>> _future;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _future = _repo.getParties(type: widget.type, search: _search);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        maxChildSize: 0.9,
        builder: (context, scrollController) {
          return Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                    color: AppColors.border,
                    borderRadius: BorderRadius.circular(2)),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        autofocus: true,
                        decoration: const InputDecoration(
                          hintText: 'Search party…',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onChanged: (v) => setState(() {
                          _search = v;
                          _load();
                        }),
                      ),
                    ),
                    const SizedBox(width: 8),
                    TextButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('New'),
                      onPressed: () async {
                        final created = await Navigator.push<dynamic>(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const AddEditPartyScreen()),
                        );
                        if (created == true) {
                          setState(_load);
                          ref.invalidate(partyListProvider);
                        }
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Party>>(
                  future: _future,
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final parties = snap.data!;
                    if (parties.isEmpty) {
                      return const Center(
                        child: Text('No parties found',
                            style: TextStyle(color: AppColors.textSecondary)),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      itemCount: parties.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final p = parties[i];
                        final bal = p.netBalance;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                AppColors.primary.withValues(alpha: 0.1),
                            child: Text(
                              p.name.isNotEmpty ? p.name[0].toUpperCase() : '?',
                              style: const TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.bold),
                            ),
                          ),
                          title: Text(p.name),
                          subtitle: p.phone != null ? Text(p.phone!) : null,
                          trailing: bal == 0
                              ? null
                              : Text(
                                  Formatters.currency(bal.abs()),
                                  style: TextStyle(
                                    color: bal >= 0
                                        ? AppColors.income
                                        : AppColors.expense,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                          onTap: () => Navigator.pop(context, p),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
