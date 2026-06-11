import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../items/models/item_unit.dart';
import '../../items/models/tax_rate.dart';
import '../utils/txn_calc.dart';
import 'line_draft.dart';

/// One editable line on a transaction form, styled like the Vyapar billed-item
/// card: a numbered index chip, name + line total on the header row, then a
/// read-only "qty unit × price = ₹total" subtotal summary, with the editable
/// qty / price / discount / tax inputs kept inline below. Edits the supplied
/// [draft] in place and calls [onChanged] after any input change so the parent
/// can recompute totals. [onRemove] deletes the line.
class ItemLineWidget extends StatefulWidget {
  final int index;
  final LineDraft draft;
  final List<TaxRate> taxRates;
  final bool isPurchase;
  final bool interState;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const ItemLineWidget({
    super.key,
    required this.index,
    required this.draft,
    required this.taxRates,
    required this.isPurchase,
    required this.interState,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<ItemLineWidget> createState() => _ItemLineWidgetState();
}

class _ItemLineWidgetState extends State<ItemLineWidget> {
  late final TextEditingController _qty;
  late final TextEditingController _price;
  late final TextEditingController _disc;

  @override
  void initState() {
    super.initState();
    _qty = TextEditingController(text: _fmt(widget.draft.quantity));
    _price = TextEditingController(text: _fmt(widget.draft.unitPrice));
    _disc = TextEditingController(
        text: widget.draft.discountValue == 0 ? '' : _fmt(widget.draft.discountValue));
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  @override
  void dispose() {
    _qty.dispose();
    _price.dispose();
    _disc.dispose();
    super.dispose();
  }

  void _recalc() => widget.onChanged();

  @override
  Widget build(BuildContext context) {
    final d = widget.draft;
    final line = d.toItem(0);
    final computed = TxnCalc.computeLine(line, interState: widget.interState);
    final unit = d.unitName.isEmpty ? '' : ' ${d.unitName}';
    final discPct =
        d.discountType == 'percent' ? d.discountValue : 0.0;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppColors.background(context),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.dividerOf(context)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: #index chip · name · line total
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 4),
            child: Row(
              children: [
                _indexChip(widget.index),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    d.itemName,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  Formatters.currency(computed.totalAmount),
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 16),
                ),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  visualDensity: VisualDensity.compact,
                  color: AppColors.textSecondary,
                  onPressed: widget.onRemove,
                ),
              ],
            ),
          ),
          // Subtotal summary line — "5 Bag × 2 = ₹10"
          _summaryRow(
            'Item Subtotal',
            '${_fmt(d.quantity)}$unit × ${_fmt(d.unitPrice)} = '
                '${Formatters.currency(d.quantity * d.unitPrice)}',
          ),
          // Discount
          _summaryRow(
            'Discount (${d.discountType == 'flat' ? '₹' : '%'}): '
                '${_fmt(d.discountType == 'flat' ? d.discountValue : discPct)}',
            Formatters.currency(computed.discountAmount),
            color: AppColors.pending,
          ),
          // Tax
          _summaryRow(
            'Tax : ${_fmt(d.taxRate)}%',
            Formatters.currency(computed.taxAmount),
          ),
          // Editable inputs are always shown (no Edit/Hide toggle) so qty / price
          // / discount / tax can be typed the moment an item is added.
          _editors(d),
        ],
      ),
    );
  }

  Widget _indexChip(int index) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.dividerOf(context)),
      ),
      child: Text('#$index',
          style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary)),
    );
  }

  Widget _summaryRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13, color: color ?? AppColors.textSecondary),
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Text(value,
              style: TextStyle(
                  fontSize: 13, color: color ?? AppColors.textSecondary)),
        ],
      ),
    );
  }

  Widget _editors(LineDraft d) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface(context),
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(8)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (d.tiers.isNotEmpty) ...[
                SizedBox(
                  width: 96,
                  child: _UnitDropdown(
                    tiers: d.tiers,
                    selected: d.selectedTier,
                    onChanged: (t) {
                      setState(() {
                        d.applyTier(t, isPurchase: widget.isPurchase);
                        _price.text = _fmt(d.unitPrice);
                      });
                      _recalc();
                    },
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: _numField(_qty, 'Qty', (v) {
                  d.quantity = double.tryParse(v) ?? 0;
                  _recalc();
                }),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _numField(_price, '@ ₹', (v) {
                  d.unitPrice = double.tryParse(v) ?? 0;
                  _recalc();
                }),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SizedBox(
                width: 96,
                child: _numField(_disc, 'Disc', (v) {
                  d.discountValue = double.tryParse(v) ?? 0;
                  if (d.discountType == 'none' && d.discountValue > 0) {
                    d.discountType = 'percent';
                  }
                  _recalc();
                }),
              ),
              const SizedBox(width: 4),
              _DiscToggle(
                type: d.discountType == 'none' ? 'percent' : d.discountType,
                onChanged: (t) {
                  setState(() => d.discountType = t);
                  _recalc();
                },
              ),
              const SizedBox(width: 12),
              Expanded(child: _taxDropdown(d)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numField(
      TextEditingController c, String label, ValueChanged<String> onChanged) {
    return TextField(
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
      ],
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      onChanged: onChanged,
    );
  }

  Widget _taxDropdown(LineDraft d) {
    // Resolve current selection by id (null ⇒ first matching by rate).
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
      decoration: const InputDecoration(
        labelText: 'Tax',
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      items: widget.taxRates
          .map((t) => DropdownMenuItem(
                value: t.id,
                child: Text(
                  t.rate == 0 ? t.name : '${t.name} (${_fmt(t.rate)}%)',
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
        _recalc();
      },
    );
  }
}

class _UnitDropdown extends StatelessWidget {
  final List<ItemUnit> tiers;
  final ItemUnit? selected;
  final ValueChanged<ItemUnit> onChanged;

  const _UnitDropdown({
    required this.tiers,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final value = tiers.any((t) => t.id == selected?.id) ? selected?.id : null;
    return DropdownButtonFormField<int>(
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: 'Unit',
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      items: tiers
          .map((t) => DropdownMenuItem(
                value: t.id,
                child: Text(t.unitName,
                    style: const TextStyle(fontSize: 13),
                    overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: (id) {
        final tier = tiers.firstWhere((t) => t.id == id);
        onChanged(tier);
      },
    );
  }
}

class _DiscToggle extends StatelessWidget {
  final String type; // 'percent' | 'flat'
  final ValueChanged<String> onChanged;
  const _DiscToggle({required this.type, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(type == 'percent' ? 'flat' : 'percent'),
      child: Container(
        height: 36,
        width: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(type == 'percent' ? '%' : '₹',
            style: const TextStyle(
                color: AppColors.primary, fontWeight: FontWeight.bold)),
      ),
    );
  }
}
