import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../models/inventory_item.dart';
import '../providers/inventory_providers.dart';
import '../repositories/inventory_repository.dart';
import '../services/inventory_pdf_service.dart';
import '../widgets/inventory_item_card.dart';
import 'item_journey_screen.dart';

/// Inventory list — a stock "bank statement" reached from the drawer. Read-only.
class InventoryListScreen extends ConsumerStatefulWidget {
  const InventoryListScreen({super.key});

  @override
  ConsumerState<InventoryListScreen> createState() =>
      _InventoryListScreenState();
}

class _InventoryListScreenState extends ConsumerState<InventoryListScreen> {
  final _searchCtrl = TextEditingController();
  bool _searching = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _openJourney(InventoryItem item) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ItemJourneyScreen(itemId: item.id, itemName: item.name),
      ),
    );
  }

  /// Builds a stock-summary PDF of the current (sorted/filtered) inventory and
  /// opens the system print / share dialog. Works on Android + Windows.
  Future<void> _printInventory() async {
    final items = await ref.read(inventoryListProvider.future);
    if (!mounted) return;
    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No inventory items to print')),
      );
      return;
    }
    try {
      await Printing.layoutPdf(onLayout: (_) => InventoryPdfService.build(items));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not print: $e')));
      }
    }
  }

  static const _sortLabels = {
    InventorySort.mostActive: 'Most Active',
    InventorySort.alphabetical: 'Alphabetical',
    InventorySort.lowStockFirst: 'Low Stock First',
  };

  @override
  Widget build(BuildContext context) {
    final sort = ref.watch(inventorySortProvider);
    final search = ref.watch(inventorySearchProvider);
    final itemsAsync = ref.watch(inventoryListProvider);

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 16),
                cursorColor: Colors.white,
                decoration: const InputDecoration(
                  hintText: 'Search items',
                  hintStyle: TextStyle(color: Colors.white70),
                  border: InputBorder.none,
                ),
                onChanged: (v) =>
                    ref.read(inventorySearchProvider.notifier).state = v,
              )
            : const Text('Inventory'),
        actions: [
          if (!_searching)
            IconButton(
              icon: const Icon(Icons.print_outlined),
              tooltip: 'Print inventory',
              onPressed: _printInventory,
            ),
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () {
              setState(() {
                _searching = !_searching;
                if (!_searching) {
                  _searchCtrl.clear();
                  ref.read(inventorySearchProvider.notifier).state = '';
                }
              });
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // Sort selector
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                const Text('Sort: ',
                    style: TextStyle(color: AppColors.textSecondary)),
                DropdownButton<InventorySort>(
                  value: sort,
                  underline: const SizedBox.shrink(),
                  items: _sortLabels.entries
                      .map((e) => DropdownMenuItem(
                          value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (v) {
                    if (v != null) {
                      ref.read(inventorySortProvider.notifier).state = v;
                    }
                  },
                ),
              ],
            ),
          ),
          Expanded(
            child: itemsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Error: $e')),
              data: (items) {
                if (items.isEmpty) {
                  return _EmptyInventory(searching: search.isNotEmpty);
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                  itemCount: items.length,
                  itemBuilder: (_, i) => InventoryItemCard(
                    item: items[i],
                    onTap: () => _openJourney(items[i]),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyInventory extends StatelessWidget {
  final bool searching;

  const _EmptyInventory({required this.searching});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(searching ? Icons.search_off : Icons.inventory_2_outlined,
                size: 64, color: AppColors.textHint),
            const SizedBox(height: 16),
            Text(
              searching ? 'No items match your search' : 'No items in inventory yet',
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            if (!searching) ...[
              const SizedBox(height: 8),
              const Text(
                'Add items from the Items module to start tracking',
                style: TextStyle(color: AppColors.textSecondary),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
