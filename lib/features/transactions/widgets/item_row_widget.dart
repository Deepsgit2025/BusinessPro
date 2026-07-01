import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../items/models/item.dart';
import '../../items/models/tax_rate.dart';
import '../../items/repositories/item_repository.dart';
import '../utils/txn_calc.dart';
import 'line_draft.dart';

/// Compact, single-row item editor for the WIDE (Windows/desktop) invoice
/// layout — one line per item, columns laid out horizontally:
///
///   Item Name | Qty | Unit | @ ₹ | Tax % | Disc | Amount | Incl. | ✕
///
/// The Item Name cell is a free-type autocomplete over saved items (like the
/// billing-name field): picking a saved item calls [onItemPicked] so the parent
/// applies its tiers/price/tax; free text just keeps the typed name. All other
/// cells edit the [draft] in place and call [onChanged]. Mobile keeps the
/// separate card-style ItemLineWidget — this widget is desktop-only.
class ItemRowWidget extends StatefulWidget {
  final int index;
  final LineDraft draft;
  final List<TaxRate> taxRates;
  final bool isPurchase;
  final bool interState;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  /// Called when the user selects a saved item from the dropdown. The parent
  /// resolves the item's tiers/price/tax onto the draft (async) then rebuilds.
  final ValueChanged<Item> onItemPicked;

  const ItemRowWidget({
    super.key,
    required this.index,
    required this.draft,
    required this.taxRates,
    required this.isPurchase,
    required this.interState,
    required this.onChanged,
    required this.onRemove,
    required this.onItemPicked,
  });

  @override
  State<ItemRowWidget> createState() => _ItemRowWidgetState();
}

class _ItemRowWidgetState extends State<ItemRowWidget> {
  final _itemRepo = ItemRepository();
  late final TextEditingController _name;
  late final TextEditingController _qty;
  late final TextEditingController _price;
  late final TextEditingController _disc;
  final _nameFocus = FocusNode();

  List<Item> _allItems = [];

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.draft.itemName);
    _qty = TextEditingController(text: _fmt(widget.draft.quantity));
    _price = TextEditingController(text: _fmt(widget.draft.unitPrice));
    _disc = TextEditingController(
        text: widget.draft.discountValue == 0
            ? ''
            : _fmt(widget.draft.discountValue));
    _loadItems();
  }

  Future<void> _loadItems() async {
    final items = await _itemRepo.getItems();
    if (!mounted) return;
    setState(() => _allItems = items);
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _price.dispose();
    _disc.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  Iterable<Item> _matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _allItems.take(20);
    return _allItems
        .where((i) => i.name.toLowerCase().contains(q))
        .take(20);
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final computed = TxnCalc.computeLine(d.toItem(0), interState: widget.interState);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Item name (free-type + saved-items dropdown).
          Expanded(flex: 34, child: _nameCell()),
          const SizedBox(width: 6),
          // Qty
          Expanded(flex: 9, child: _numCell(_qty, 'Qty', (v) {
            d.quantity = double.tryParse(v) ?? 0;
            widget.onChanged();
          })),
          const SizedBox(width: 6),
          // Unit (tier dropdown when available, else static unit label)
          Expanded(flex: 11, child: _unitCell(d)),
          const SizedBox(width: 6),
          // Price / unit
          Expanded(flex: 12, child: _numCell(_price, '@ ₹', (v) {
            d.unitPrice = double.tryParse(v) ?? 0;
            widget.onChanged();
          })),
          const SizedBox(width: 6),
          // Tax %
          Expanded(flex: 13, child: _taxCell(d)),
          const SizedBox(width: 6),
          // Discount
          Expanded(flex: 11, child: _discCell(d)),
          const SizedBox(width: 6),
          // Amount (read-only)
          Expanded(
            flex: 13,
            child: Align(
              alignment: Alignment.centerRight,
              child: Text(
                Formatters.currency(computed.totalAmount),
                style: const TextStyle(fontWeight: FontWeight.w700),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 4),
          // Incl. tax toggle (only meaningful with a tax rate).
          _inclToggle(d),
          // Remove
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            color: AppColors.textSecondary,
            tooltip: 'Remove',
            onPressed: widget.onRemove,
          ),
        ],
      ),
    );
  }

  Widget _nameCell() {
    return RawAutocomplete<Item>(
      textEditingController: _name,
      focusNode: _nameFocus,
      displayStringForOption: (i) => i.name,
      optionsBuilder: (value) => _matches(value.text),
      onSelected: (item) {
        _name.text = item.name;
        widget.onItemPicked(item);
        _nameFocus.unfocus();
      },
      fieldViewBuilder: (context, controller, focusNode, _) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          style: const TextStyle(fontSize: 13),
          decoration: _dec('Item name'),
          onChanged: (v) {
            // Keep the draft's free-text name in sync as the user types.
            widget.draft.itemName = v;
            widget.onChanged();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final list = options.toList();
        if (list.isEmpty) return const SizedBox.shrink();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 260, maxWidth: 360),
              child: ListView.separated(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final it = list[i];
                  return ListTile(
                    dense: true,
                    title: Text(it.name, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      Formatters.currency(
                          widget.isPurchase ? it.purchasePrice : it.salePrice),
                      style: const TextStyle(fontSize: 11),
                    ),
                    onTap: () => onSelected(it),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _numCell(
      TextEditingController c, String label, ValueChanged<String> onChanged) {
    return TextField(
      controller: c,
      style: const TextStyle(fontSize: 13),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
      ],
      decoration: _dec(label),
      onChanged: onChanged,
    );
  }

  Widget _unitCell(LineDraft d) {
    if (d.tiers.isEmpty) {
      // Free-text line: no tiers, show a disabled-looking unit placeholder.
      return Text(
        d.unitName.isEmpty ? '—' : d.unitName,
        style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
        textAlign: TextAlign.center,
      );
    }
    final value = d.tiers.any((t) => t.id == d.selectedTier?.id)
        ? d.selectedTier?.id
        : null;
    return DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
      decoration: _dec('Unit'),
      items: d.tiers
          .map((t) => DropdownMenuItem(
                value: t.id,
                child: Text(t.unitName,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: (id) {
        final tier = d.tiers.firstWhere((t) => t.id == id);
        setState(() {
          d.applyTier(tier, isPurchase: widget.isPurchase);
          _price.text = _fmt(d.unitPrice);
        });
        widget.onChanged();
      },
    );
  }

  Widget _taxCell(LineDraft d) {
    int? value = d.taxRateId;
    if (value == null) {
      for (final t in widget.taxRates) {
        if (t.rate == d.taxRate) {
          value = t.id;
          break;
        }
      }
    }
    return DropdownButtonFormField<int>(
      initialValue: widget.taxRates.any((t) => t.id == value) ? value : null,
      isExpanded: true,
      style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
      decoration: _dec('Tax'),
      items: widget.taxRates
          .map((t) => DropdownMenuItem(
                value: t.id,
                child: Text(
                  t.rate == 0 ? t.name : '${_fmt(t.rate)}%',
                  style: const TextStyle(fontSize: 13),
                  overflow: TextOverflow.ellipsis,
                ),
              ))
          .toList(),
      onChanged: (id) {
        final tax = widget.taxRates.firstWhere((t) => t.id == id);
        setState(() {
          d.taxRateId = tax.id;
          d.taxRate = tax.rate;
        });
        widget.onChanged();
      },
    );
  }

  Widget _discCell(LineDraft d) {
    return Row(
      children: [
        Expanded(
          child: _numCell(_disc, 'Disc', (v) {
            d.discountValue = double.tryParse(v) ?? 0;
            if (d.discountType == 'none' && d.discountValue > 0) {
              d.discountType = 'percent';
            }
            widget.onChanged();
          }),
        ),
        GestureDetector(
          onTap: () {
            setState(() => d.discountType =
                d.discountType == 'flat' ? 'percent' : 'flat');
            widget.onChanged();
          },
          child: Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              d.discountType == 'flat' ? '₹' : '%',
              style: const TextStyle(
                  color: AppColors.primary, fontWeight: FontWeight.bold),
            ),
          ),
        ),
      ],
    );
  }

  /// Compact "Incl." tax toggle — hidden (placeholder space) when the line has
  /// no tax rate, since there's nothing to extract.
  Widget _inclToggle(LineDraft d) {
    if (d.taxRate <= 0) return const SizedBox(width: 40);
    return Tooltip(
      message: d.taxInclusive ? 'Price includes tax' : 'Tax added on top',
      child: GestureDetector(
        onTap: () {
          setState(() => d.taxInclusive = !d.taxInclusive);
          widget.onChanged();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: d.taxInclusive
                ? AppColors.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
                color: d.taxInclusive
                    ? AppColors.primary
                    : AppColors.dividerOf(context)),
          ),
          child: Text(
            'Incl.',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: d.taxInclusive
                  ? AppColors.primary
                  : AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  // The top column headers label each cell, so rows use a faint hint (shown
  // only when empty) instead of a persistent floating label that would repeat
  // the header on every row.
  InputDecoration _dec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(fontSize: 12, color: AppColors.textHint),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        border: const OutlineInputBorder(),
      );
}
