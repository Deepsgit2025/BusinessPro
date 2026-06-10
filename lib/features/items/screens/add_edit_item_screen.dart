import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../models/item.dart';
import '../models/item_unit.dart';
import '../models/unit.dart';
import '../providers/item_providers.dart';

/// Add or edit an item. Pass [item] to edit; omit to add.
class AddEditItemScreen extends ConsumerStatefulWidget {
  final Item? item;
  const AddEditItemScreen({super.key, this.item});

  bool get isEdit => item != null;

  @override
  ConsumerState<AddEditItemScreen> createState() => _AddEditItemScreenState();
}

class _AddEditItemScreenState extends ConsumerState<AddEditItemScreen> {
  final _formKey = GlobalKey<FormState>();

  late String _itemType;
  int? _categoryId;
  int? _taxRateId;
  bool _taxInclusive = false;
  bool _saving = false;

  /// Selling-unit tiers. The base tier (is_base_unit) is always index 0 after
  /// [_sortTiers]; it tracks stock and has conversion_factor 1.
  List<ItemUnit> _tiers = [];

  late final TextEditingController _name;
  late final TextEditingController _sku;
  late final TextEditingController _barcode;
  late final TextEditingController _hsn;
  late final TextEditingController _openingStock;
  late final TextEditingController _minStock;
  late final TextEditingController _description;

  @override
  void initState() {
    super.initState();
    final it = widget.item;
    _itemType = it?.itemType ?? 'product';
    _categoryId = it?.categoryId;
    _taxRateId = it?.taxRateId;
    _taxInclusive = it?.taxInclusive ?? false;

    _name = TextEditingController(text: it?.name ?? '');
    _sku = TextEditingController(text: it?.sku ?? '');
    _barcode = TextEditingController(text: it?.barcode ?? '');
    _hsn = TextEditingController(text: it?.hsnCode ?? '');
    _openingStock = TextEditingController(text: _money(it?.openingStock));
    _minStock = TextEditingController(text: _money(it?.minStockLevel));
    _description = TextEditingController(text: it?.description ?? '');

    if (widget.isEdit) {
      _loadTiers();
    }
  }

  Future<void> _loadTiers() async {
    final repo = ref.read(itemUnitRepositoryProvider);
    final loaded = await repo.getItemUnits(widget.item!.id!);
    if (!mounted) return;
    setState(() => _tiers = _sortTiers(loaded));
  }

  static String _money(double? v) =>
      (v == null || v == 0) ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());

  @override
  void dispose() {
    for (final c in [
      _name, _sku, _barcode, _hsn, _openingStock, _minStock, _description,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  double _num(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;

  /// Base tier first, then by conversion factor ascending (smallest packing up).
  List<ItemUnit> _sortTiers(List<ItemUnit> tiers) {
    final sorted = [...tiers];
    sorted.sort((a, b) {
      if (a.isBaseUnit != b.isBaseUnit) return a.isBaseUnit ? -1 : 1;
      return a.conversionFactor.compareTo(b.conversionFactor);
    });
    return sorted;
  }

  ItemUnit? get _baseTier =>
      _tiers.where((t) => t.isBaseUnit).firstOrNull ??
      (_tiers.isEmpty ? null : _tiers.first);

  String get _baseUnitName => _baseTier?.unitName ?? 'base unit';

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_tiers.isEmpty) {
      _toast('Add at least one unit tier');
      return;
    }
    setState(() => _saving = true);

    final repo = ref.read(itemRepositoryProvider);
    final isProduct = _itemType == 'product';
    final item = Item(
      id: widget.item?.id,
      categoryId: _categoryId,
      taxRateId: _taxRateId,
      name: _name.text.trim(),
      itemType: _itemType,
      sku: _sku.text.trim().isEmpty ? null : _sku.text.trim(),
      barcode: _barcode.text.trim().isEmpty ? null : _barcode.text.trim(),
      hsnCode: _hsn.text.trim().isEmpty ? null : _hsn.text.trim(),
      openingStock: isProduct ? _num(_openingStock) : 0,
      minStockLevel: isProduct ? _num(_minStock) : 0,
      taxInclusive: _taxInclusive,
      description: _description.text.trim().isEmpty ? null : _description.text.trim(),
    );

    try {
      if (widget.isEdit) {
        await repo.update(item, tiers: _sortTiers(_tiers));
      } else {
        await repo.insert(item, tiers: _sortTiers(_tiers));
      }
      ref.invalidate(itemListProvider);
      if (widget.item?.id != null) {
        ref.invalidate(itemDetailProvider(widget.item!.id!));
        ref.invalidate(itemUnitsProvider(widget.item!.id!));
      }
      if (!mounted) return;
      Navigator.pop(context, true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Item ${widget.isEdit ? 'updated' : 'saved'}')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _toast('Could not save: $e');
    }
  }

  void _toast(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  // ─── Tier editing ────────────────────────────────────────────────────────

  Future<void> _editTier({ItemUnit? existing, int? index}) async {
    final units = ref.read(unitsProvider).valueOrNull ?? const <Unit>[];
    if (units.isEmpty) {
      _toast('Add a unit first');
      return;
    }
    // The very first tier added becomes the base unit automatically.
    final isBase = existing?.isBaseUnit ?? _tiers.isEmpty;
    final result = await showModalBottomSheet<ItemUnit>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _TierSheet(
        units: units,
        existing: existing,
        isBase: isBase,
        baseUnitName: isBase ? null : _baseUnitName,
      ),
    );
    if (result == null) return;

    setState(() {
      var next = [..._tiers];
      // Enforce single default-sale / default-purchase across the set.
      if (result.isDefaultSale) {
        next = next.map((t) => t.copyWith(isDefaultSale: false)).toList();
      }
      if (result.isDefaultPurchase) {
        next = next.map((t) => t.copyWith(isDefaultPurchase: false)).toList();
      }
      if (index != null) {
        next[index] = result;
      } else {
        next.add(result);
      }
      // Guarantee at least one default of each kind (first tier wins).
      if (!next.any((t) => t.isDefaultSale)) {
        next[0] = next[0].copyWith(isDefaultSale: true);
      }
      if (!next.any((t) => t.isDefaultPurchase)) {
        next[0] = next[0].copyWith(isDefaultPurchase: true);
      }
      _tiers = _sortTiers(next);
    });
  }

  void _deleteTier(int index) {
    final tier = _tiers[index];
    if (tier.isBaseUnit) {
      _toast('The base unit cannot be deleted');
      return;
    }
    setState(() => _tiers = _sortTiers([..._tiers]..removeAt(index)));
  }

  // ─── Inline master-data creation ───────────────────────────────────────────

  Future<void> _addCategoryInline() async {
    final name = await _promptText('New Category', 'Category name');
    if (name == null || name.trim().isEmpty) return;
    final repo = ref.read(categoryRepositoryProvider);
    final id = await repo.insert(name);
    ref.invalidate(categoriesProvider);
    setState(() => _categoryId = id);
  }

  Future<String?> _promptText(String title, String label) {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(labelText: label),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(categoriesProvider);
    final taxRatesAsync = ref.watch(taxRatesProvider);
    final isProduct = _itemType == 'product';

    return Scaffold(
      appBar: AppBar(title: Text(widget.isEdit ? 'Edit Item' : 'Add Item')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _field(_name, 'Item Name *', textCapitalization: TextCapitalization.words,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Item name is required' : null),

            _label('Item Type'),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'product', label: Text('Product')),
                ButtonSegment(value: 'service', label: Text('Service')),
              ],
              selected: {_itemType},
              onSelectionChanged: (s) => setState(() => _itemType = s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: 16),

            // Category dropdown + Add New
            categoriesAsync.maybeWhen(
              data: (cats) => _DropdownWithAdd<int>(
                label: 'Category',
                value: cats.any((c) => c.id == _categoryId) ? _categoryId : null,
                items: cats
                    .map((c) => DropdownMenuItem(value: c.id, child: Text(c.name)))
                    .toList(),
                onChanged: (v) => setState(() => _categoryId = v),
                onAdd: _addCategoryInline,
              ),
              orElse: () => const SizedBox.shrink(),
            ),
            const SizedBox(height: 12),

            _field(_sku, 'SKU'),
            _field(_barcode, 'Barcode'),
            _field(_hsn, 'HSN / SAC Code'),

            // Unit & pricing tiers
            _label('Unit & Pricing'),
            _TierTable(
              tiers: _tiers,
              baseUnitName: _baseUnitName,
              onAdd: () => _editTier(),
              onEdit: (i) => _editTier(existing: _tiers[i], index: i),
              onDelete: _deleteTier,
            ),
            const SizedBox(height: 16),

            // Tax rate dropdown
            taxRatesAsync.maybeWhen(
              data: (rates) => DropdownButtonFormField<int>(
                initialValue: rates.any((r) => r.id == _taxRateId) ? _taxRateId : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Tax Rate'),
                items: rates
                    .map((r) => DropdownMenuItem(value: r.id, child: Text(r.name)))
                    .toList(),
                onChanged: (v) => setState(() => _taxRateId = v),
              ),
              orElse: () => const SizedBox.shrink(),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _taxInclusive,
              onChanged: (v) => setState(() => _taxInclusive = v),
              title: const Text('Tax Inclusive', style: TextStyle(fontSize: 14)),
              activeThumbColor: AppColors.primary,
            ),

            // Stock fields — products only. Stock is always in the base unit.
            if (isProduct) ...[
              _label('Stock (in $_baseUnitName)'),
              Row(
                children: [
                  Expanded(child: _field(_openingStock, 'Opening Stock',
                      keyboardType: TextInputType.number, dense: true)),
                  const SizedBox(width: 12),
                  Expanded(child: _field(_minStock, 'Min Stock Level',
                      keyboardType: TextInputType.number, dense: true)),
                ],
              ),
              const SizedBox(height: 12),
            ],

            _label('Description'),
            _field(_description, 'Description', maxLines: 3),

            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        height: 20, width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Save'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8, top: 8),
        child: Text(text,
            style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
                letterSpacing: 0.5)),
      );

  Widget _field(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    int maxLines = 1,
    bool dense = false,
    TextCapitalization textCapitalization = TextCapitalization.none,
    String? Function(String?)? validator,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: dense ? 0 : 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        maxLines: maxLines,
        textCapitalization: textCapitalization,
        validator: validator,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }
}

/// The unit-tiers list with an [+ Add] header. Tap a row to edit, delete icon
/// to remove (base unit is protected).
class _TierTable extends StatelessWidget {
  final List<ItemUnit> tiers;
  final String baseUnitName;
  final VoidCallback onAdd;
  final ValueChanged<int> onEdit;
  final ValueChanged<int> onDelete;

  const _TierTable({
    required this.tiers,
    required this.baseUnitName,
    required this.onAdd,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.divider),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
            child: Row(
              children: [
                const Expanded(
                  child: Text('UNIT TIERS',
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                          color: AppColors.textSecondary)),
                ),
                TextButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add'),
                ),
              ],
            ),
          ),
          if (tiers.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 16),
              child: Text(
                'No units yet. Add at least one — the first becomes the base unit '
                'used for stock tracking.',
                style: TextStyle(fontSize: 12, color: AppColors.textHint),
              ),
            )
          else
            ...List.generate(tiers.length, (i) {
              final t = tiers[i];
              return Column(
                children: [
                  const Divider(height: 1),
                  ListTile(
                    dense: true,
                    onTap: () => onEdit(i),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(t.unitName,
                              style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                        if (t.isBaseUnit) ...[
                          const SizedBox(width: 6),
                          _chip('BASE'),
                        ],
                        if (t.isDefaultSale) ...[
                          const SizedBox(width: 6),
                          _chip('SALE'),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      t.isBaseUnit
                          ? 'Stock unit • Sale ${Formatters.currency(t.salePrice)}'
                          : '1 ${t.unitName} = ${Formatters.qty(t.conversionFactor)} '
                              '$baseUnitName • Sale ${Formatters.currency(t.salePrice)}',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: IconButton(
                      icon: Icon(
                        Icons.delete_outline,
                        size: 20,
                        color: t.isBaseUnit ? AppColors.textHint : AppColors.expense,
                      ),
                      onPressed: t.isBaseUnit ? null : () => onDelete(i),
                    ),
                  ),
                ],
              );
            }),
        ],
      ),
    );
  }

  Widget _chip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(text,
            style: const TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
                letterSpacing: 0.5)),
      );
}

/// Bottom sheet to add or edit a single unit tier.
class _TierSheet extends StatefulWidget {
  final List<Unit> units;
  final ItemUnit? existing;
  final bool isBase;

  /// Base unit name shown in the "Contains … `base`" suffix. Null for the base
  /// tier itself (its conversion is locked to 1).
  final String? baseUnitName;

  const _TierSheet({
    required this.units,
    required this.existing,
    required this.isBase,
    required this.baseUnitName,
  });

  @override
  State<_TierSheet> createState() => _TierSheetState();
}

class _TierSheetState extends State<_TierSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _conversion;
  late final TextEditingController _sale;
  late final TextEditingController _purchase;
  late final TextEditingController _mrp;
  int? _unitId;
  bool _defaultSale = false;
  bool _defaultPurchase = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.unitName ?? '');
    _conversion = TextEditingController(
        text: widget.isBase ? '1' : _money(e?.conversionFactor));
    _sale = TextEditingController(text: _money(e?.salePrice));
    _purchase = TextEditingController(text: _money(e?.purchasePrice));
    _mrp = TextEditingController(text: _money(e?.mrp));
    _unitId = e?.unitId ?? (widget.units.isNotEmpty ? widget.units.first.id : null);
    _defaultSale = e?.isDefaultSale ?? widget.isBase;
    _defaultPurchase = e?.isDefaultPurchase ?? widget.isBase;
  }

  static String _money(double? v) =>
      (v == null || v == 0) ? '' : (v == v.roundToDouble() ? v.toInt().toString() : v.toString());

  @override
  void dispose() {
    for (final c in [_name, _conversion, _sale, _purchase, _mrp]) {
      c.dispose();
    }
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final unit = widget.units.firstWhere((u) => u.id == _unitId);
    final name = _name.text.trim().isEmpty ? unit.name : _name.text.trim();
    final conversion = widget.isBase
        ? 1.0
        : (double.tryParse(_conversion.text.trim()) ?? 0);
    Navigator.pop(
      context,
      ItemUnit(
        id: widget.existing?.id,
        itemId: widget.existing?.itemId,
        unitId: _unitId!,
        unitName: name,
        conversionFactor: conversion,
        salePrice: double.tryParse(_sale.text.trim()) ?? 0,
        purchasePrice: double.tryParse(_purchase.text.trim()) ?? 0,
        mrp: double.tryParse(_mrp.text.trim()) ?? 0,
        isBaseUnit: widget.isBase,
        isDefaultSale: _defaultSale,
        isDefaultPurchase: _defaultPurchase,
        sortOrder: widget.existing?.sortOrder ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(
          left: 16, right: 16, top: 16, bottom: 16 + bottomInset),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.existing == null
                  ? (widget.isBase ? 'Base Unit' : 'Add Unit Tier')
                  : 'Edit Unit Tier',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            if (widget.isBase)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  'The base unit tracks stock. Its conversion is always 1.',
                  style: TextStyle(fontSize: 12, color: AppColors.textHint),
                ),
              ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                  labelText: 'Unit Name', hintText: 'e.g. Bottle'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<int>(
              initialValue: _unitId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Unit'),
              items: widget.units
                  .map((u) => DropdownMenuItem(
                      value: u.id, child: Text('${u.name} (${u.shortName})')))
                  .toList(),
              onChanged: (v) => setState(() => _unitId = v),
              validator: (v) => v == null ? 'Select a unit' : null,
            ),
            const SizedBox(height: 12),
            if (!widget.isBase)
              TextFormField(
                controller: _conversion,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: 'Contains',
                  suffixText: widget.baseUnitName,
                  helperText: '1 of this unit = how many ${widget.baseUnitName}?',
                ),
                validator: (v) {
                  final n = double.tryParse(v?.trim() ?? '');
                  if (n == null || n <= 0) return 'Must be greater than 0';
                  return null;
                },
              ),
            if (!widget.isBase) const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _sale,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Sale Price ₹'),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isNotEmpty && double.tryParse(t) == null) {
                        return 'Enter a valid price';
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: _purchase,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Purchase ₹'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _mrp,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'MRP ₹'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _defaultSale,
              onChanged: (v) => setState(() => _defaultSale = v),
              title: const Text('Default for Sale', style: TextStyle(fontSize: 14)),
              activeThumbColor: AppColors.primary,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _defaultPurchase,
              onChanged: (v) => setState(() => _defaultPurchase = v),
              title:
                  const Text('Default for Purchase', style: TextStyle(fontSize: 14)),
              activeThumbColor: AppColors.primary,
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submit,
                child: const Text('Save Tier'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A dropdown paired with a trailing "+" that triggers inline creation.
class _DropdownWithAdd<T> extends StatelessWidget {
  final String label;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;
  final VoidCallback onAdd;

  const _DropdownWithAdd({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<T>(
            initialValue: value,
            isExpanded: true,
            decoration: InputDecoration(labelText: label),
            items: items,
            onChanged: onChanged,
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filledTonal(
          onPressed: onAdd,
          icon: const Icon(Icons.add),
          tooltip: 'Add new',
          style: IconButton.styleFrom(
            backgroundColor: AppColors.primary.withValues(alpha: 0.1),
            foregroundColor: AppColors.primary,
          ),
        ),
      ],
    );
  }
}
