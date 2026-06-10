import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../models/tax_rate.dart';
import '../providers/item_providers.dart';

/// Manage tax rates: list, add custom, delete.
class TaxRatesScreen extends ConsumerWidget {
  const TaxRatesScreen({super.key});

  Future<TaxRate?> _promptRate(BuildContext context) {
    final nameCtrl = TextEditingController();
    final totalCtrl = TextEditingController();
    final cgstCtrl = TextEditingController();
    final sgstCtrl = TextEditingController();
    final igstCtrl = TextEditingController();
    double n(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

    return showDialog<TaxRate>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New Tax Rate'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Name (e.g. GST 18%)'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: totalCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Total %'),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: cgstCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'CGST %'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: sgstCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'SGST %'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: igstCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'IGST %'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              if (nameCtrl.text.trim().isEmpty) return;
              Navigator.pop(
                ctx,
                TaxRate(
                  name: nameCtrl.text.trim(),
                  rate: n(totalCtrl),
                  cgstRate: n(cgstCtrl),
                  sgstRate: n(sgstCtrl),
                  igstRate: n(igstCtrl),
                ),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref, TaxRate rate) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${rate.name}?'),
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
      await ref.read(taxRateRepositoryProvider).softDelete(rate.id!);
      ref.invalidate(taxRatesProvider);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ratesAsync = ref.watch(taxRatesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Tax Rates')),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.primary,
        onPressed: () async {
          final rate = await _promptRate(context);
          if (rate == null) return;
          await ref.read(taxRateRepositoryProvider).insert(rate);
          ref.invalidate(taxRatesProvider);
        },
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: ratesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (rates) => ListView.separated(
          itemCount: rates.length,
          separatorBuilder: (context, index) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final r = rates[i];
            return ListTile(
              title: Text(r.name),
              subtitle: Text(
                'Total ${r.rate}%  •  CGST ${r.cgstRate}%  SGST ${r.sgstRate}%  IGST ${r.igstRate}%',
                style: const TextStyle(fontSize: 11),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline, color: AppColors.expense),
                onPressed: () => _delete(context, ref, r),
              ),
            );
          },
        ),
      ),
    );
  }
}
