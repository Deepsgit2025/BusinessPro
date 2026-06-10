import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../items/models/item.dart';
import '../../items/repositories/item_repository.dart';

/// Searchable item picker bottom sheet (search by name / SKU / barcode).
/// Returns the chosen [Item], or a synthetic free-text [Item] (id == null) when
/// the user types a name and taps "Add ‹name›". Returns null if dismissed.
Future<Item?> showItemPicker(BuildContext context) {
  return showModalBottomSheet<Item>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _ItemPickerSheet(),
  );
}

class _ItemPickerSheet extends StatefulWidget {
  const _ItemPickerSheet();

  @override
  State<_ItemPickerSheet> createState() => _ItemPickerSheetState();
}

class _ItemPickerSheetState extends State<_ItemPickerSheet> {
  final _repo = ItemRepository();
  String _search = '';
  late Future<List<Item>> _future;

  @override
  void initState() {
    super.initState();
    _future = _repo.getItems();
  }

  void _load() => _future = _repo.getItems(search: _search);

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
                child: TextField(
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: 'Search item by name or barcode…',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() {
                    _search = v;
                    _load();
                  }),
                ),
              ),
              Expanded(
                child: FutureBuilder<List<Item>>(
                  future: _future,
                  builder: (context, snap) {
                    if (!snap.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final items = snap.data!;
                    return ListView(
                      controller: scrollController,
                      children: [
                        if (_search.trim().isNotEmpty)
                          ListTile(
                            leading: const Icon(Icons.add, color: AppColors.primary),
                            title: Text('Add "${_search.trim()}"'),
                            subtitle: const Text('Free-text item'),
                            onTap: () => Navigator.pop(
                              context,
                              Item(name: _search.trim()),
                            ),
                          ),
                        if (items.isEmpty && _search.trim().isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(32),
                            child: Center(
                              child: Text('No items yet',
                                  style: TextStyle(
                                      color: AppColors.textSecondary)),
                            ),
                          ),
                        ...items.map((it) => ListTile(
                              leading: CircleAvatar(
                                backgroundColor:
                                    AppColors.primary.withValues(alpha: 0.1),
                                child: Icon(
                                  it.isProduct
                                      ? Icons.inventory_2_outlined
                                      : Icons.miscellaneous_services_outlined,
                                  color: AppColors.primary,
                                  size: 20,
                                ),
                              ),
                              title: Text(it.name),
                              subtitle: Text(
                                '${Formatters.currency(it.salePrice)}'
                                '${it.isProduct ? ' · Stock ${Formatters.qty(it.currentStock, it.unitShort)}' : ''}',
                              ),
                              onTap: () => Navigator.pop(context, it),
                            )),
                      ],
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
