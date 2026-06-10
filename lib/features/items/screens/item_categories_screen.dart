import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../models/item_category.dart';
import '../providers/item_providers.dart';

/// Manage item categories: list, add (inline), rename, delete.
class ItemCategoriesScreen extends ConsumerStatefulWidget {
  const ItemCategoriesScreen({super.key});

  @override
  ConsumerState<ItemCategoriesScreen> createState() => _ItemCategoriesScreenState();
}

class _ItemCategoriesScreenState extends ConsumerState<ItemCategoriesScreen> {
  final _newCtrl = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _newCtrl.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final name = _newCtrl.text.trim();
    if (name.isEmpty || _adding) return;
    setState(() => _adding = true);
    await ref.read(categoryRepositoryProvider).insert(name);
    _newCtrl.clear();
    ref.invalidate(categoriesProvider);
    if (mounted) setState(() => _adding = false);
  }

  Future<void> _rename(ItemCategory cat) async {
    final ctrl = TextEditingController(text: cat.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename Category'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Category name'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (newName == null || newName.trim().isEmpty) return;
    await ref.read(categoryRepositoryProvider).rename(cat.id!, newName);
    ref.invalidate(categoriesProvider);
    ref.invalidate(itemListProvider);
  }

  Future<void> _delete(ItemCategory cat) async {
    final repo = ref.read(categoryRepositoryProvider);
    final count = await repo.itemCount(cat.id!);
    if (!mounted) return;

    if (count > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Cannot delete "${cat.name}" — $count item(s) use this category.'),
        ),
      );
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${cat.name}?'),
        content: const Text('This cannot be undone.'),
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
      await repo.softDelete(cat.id!);
      ref.invalidate(categoriesProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Manage Categories')),
      body: Column(
        children: [
          Expanded(
            child: categoriesAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (cats) {
                if (cats.isEmpty) {
                  return const Center(
                    child: Text('No categories yet. Add one below.',
                        style: TextStyle(color: AppColors.textSecondary)),
                  );
                }
                return ListView.separated(
                  itemCount: cats.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final cat = cats[i];
                    return ListTile(
                      title: Text(cat.name),
                      subtitle: Text('${cat.itemCount} item(s)',
                          style: const TextStyle(fontSize: 12)),
                      onTap: () => _rename(cat),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: AppColors.expense),
                        onPressed: () => _delete(cat),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const Divider(height: 1),
          // Inline add row
          Padding(
            padding: EdgeInsets.fromLTRB(
                12, 8, 12, 8 + MediaQuery.of(context).viewInsets.bottom),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _newCtrl,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      hintText: 'New category name',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _adding ? null : _add,
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
