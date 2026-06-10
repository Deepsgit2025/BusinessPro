import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../models/unit.dart';
import '../providers/item_providers.dart';

/// Manage units of measurement: list, add, edit, delete.
class UnitsScreen extends ConsumerWidget {
  const UnitsScreen({super.key});

  Future<({String name, String short})?> _promptUnit(
    BuildContext context, {
    Unit? existing,
  }) {
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final shortCtrl = TextEditingController(text: existing?.shortName ?? '');
    return showDialog<({String name, String short})>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'New Unit' : 'Edit Unit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Name (e.g. Piece)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: shortCtrl,
              decoration: const InputDecoration(labelText: 'Short name (e.g. pcs)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) return;
              Navigator.pop(ctx, (
                name: nameCtrl.text.trim(),
                short: shortCtrl.text.trim().isEmpty
                    ? nameCtrl.text.trim()
                    : shortCtrl.text.trim(),
              ));
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, Unit unit) async {
    final repo = ref.read(unitRepositoryProvider);
    final count = await repo.itemCount(unit.id!);
    if (!context.mounted) return;
    if (count > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cannot delete "${unit.name}" — $count item(s) use it.')),
      );
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${unit.name}?'),
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
      await repo.softDelete(unit.id!);
      ref.invalidate(unitsProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unitsAsync = ref.watch(unitsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Units')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        onPressed: () async {
          final result = await _promptUnit(context);
          if (result == null) return;
          await ref.read(unitRepositoryProvider).insert(result.name, result.short);
          ref.invalidate(unitsProvider);
        },
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: unitsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (units) => ListView.separated(
          itemCount: units.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final u = units[i];
            return ListTile(
              title: Text(u.name),
              subtitle: Text(u.shortName, style: const TextStyle(fontSize: 12)),
              onTap: () async {
                final result = await _promptUnit(context, existing: u);
                if (result == null) return;
                await ref
                    .read(unitRepositoryProvider)
                    .update(u.id!, result.name, result.short);
                ref.invalidate(unitsProvider);
              },
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: AppColors.expense),
                onPressed: () => _delete(context, ref, u),
              ),
            );
          },
        ),
      ),
    );
  }
}
