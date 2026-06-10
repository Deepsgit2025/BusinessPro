import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../models/item.dart';
import '../providers/item_providers.dart';
import '../widgets/item_card.dart';
import 'add_edit_item_screen.dart';
import 'item_categories_screen.dart';
import 'item_detail_screen.dart';

/// Items list — a full screen reached from the drawer's "Items" entry.
class ItemsListScreen extends ConsumerStatefulWidget {
  const ItemsListScreen({super.key});

  @override
  ConsumerState<ItemsListScreen> createState() => _ItemsListScreenState();
}

class _ItemsListScreenState extends ConsumerState<ItemsListScreen> {
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openAdd() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddEditItemScreen()),
    );
  }

  void _openDetail(Item item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ItemDetailScreen(itemId: item.id!)),
    );
  }

  void _openEdit(Item item) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => AddEditItemScreen(item: item)),
    );
  }

  Future<void> _confirmDelete(Item item) async {
    final repo = ref.read(itemRepositoryProvider);
    final txnCount = await repo.transactionCount(item.id!);
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${item.name}?'),
        content: Text(
          txnCount > 0
              ? 'This item appears in $txnCount transaction(s). Stock history '
                  'will be preserved.'
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
      await repo.softDelete(item.id!);
      ref.invalidate(itemListProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${item.name} deleted')),
        );
      }
    }
  }

  void _showOptions(Item item) {
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
                _openEdit(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AppColors.expense),
              title: const Text('Delete'),
              onTap: () {
                Navigator.pop(ctx);
                _confirmDelete(item);
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(itemFilterProvider);
    final itemsAsync = ref.watch(itemListProvider);
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Items'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) {
              if (v == 'categories') {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const ItemCategoriesScreen()),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'categories', child: Text('Manage Categories')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        onPressed: _openAdd,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => ref
                  .read(itemFilterProvider.notifier)
                  .update((s) => s.copyWith(search: v)),
              decoration: InputDecoration(
                hintText: 'Search items',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          ref
                              .read(itemFilterProvider.notifier)
                              .update((s) => s.copyWith(search: ''));
                        },
                      ),
                isDense: true,
              ),
            ),
          ),

          // Category filter chips
          categoriesAsync.maybeWhen(
            data: (cats) => SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  _CategoryChip(
                    label: 'All',
                    selected: filter.categoryId == null,
                    onTap: () => ref
                        .read(itemFilterProvider.notifier)
                        .update((s) => s.copyWith(categoryId: null)),
                  ),
                  ...cats.map((c) => _CategoryChip(
                        label: c.name,
                        selected: filter.categoryId == c.id,
                        onTap: () => ref
                            .read(itemFilterProvider.notifier)
                            .update((s) => s.copyWith(categoryId: c.id)),
                      )),
                ],
              ),
            ),
            orElse: () => const SizedBox(height: 40),
          ),
          const SizedBox(height: 4),

          // List
          Expanded(
            child: itemsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (items) {
                if (items.isEmpty) {
                  final searching = filter.search.isNotEmpty || filter.categoryId != null;
                  return _EmptyItems(searching: searching, onAdd: _openAdd);
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 88),
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final item = items[i];
                    return ItemCard(
                      item: item,
                      onTap: () => _openDetail(item),
                      onLongPress: () => _showOptions(item),
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

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: AppColors.primary,
        labelStyle: TextStyle(
          color: selected ? Colors.white : AppColors.textPrimary,
          fontSize: 12,
        ),
        backgroundColor: AppColors.cardLight,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
      ),
    );
  }
}

class _EmptyItems extends StatelessWidget {
  final bool searching;
  final VoidCallback onAdd;
  const _EmptyItems({required this.searching, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    if (searching) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off, size: 64, color: AppColors.textHint),
            SizedBox(height: 12),
            Text('No items match your filter',
                style: TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.inventory_2_outlined, size: 64, color: AppColors.textHint),
          const SizedBox(height: 16),
          const Text('No items added yet',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
          const SizedBox(height: 20),
          OutlinedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Add Item'),
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
