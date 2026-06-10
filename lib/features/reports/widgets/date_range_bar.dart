import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../repositories/reports_repository.dart';

/// The three quick presets plus a custom range, shared across report screens.
enum RangePreset { thisMonth, thisYear, custom }

/// A compact date-filter bar: three choice chips (This Month / This Year /
/// Custom) with the resolved range printed beneath. Picking "Custom" opens a
/// range picker. Calls [onChanged] with the resolved [DateRange] whenever the
/// selection changes.
class DateRangeBar extends StatefulWidget {
  final DateRange initialRange;
  final RangePreset initialPreset;
  final ValueChanged<DateRange> onChanged;

  const DateRangeBar({
    super.key,
    required this.initialRange,
    required this.onChanged,
    this.initialPreset = RangePreset.thisMonth,
  });

  @override
  State<DateRangeBar> createState() => _DateRangeBarState();
}

class _DateRangeBarState extends State<DateRangeBar> {
  late RangePreset _preset = widget.initialPreset;
  late DateRange _range = widget.initialRange;

  void _select(RangePreset preset) async {
    if (preset == RangePreset.custom) {
      final picked = await showDateRangePicker(
        context: context,
        firstDate: DateTime(2015),
        lastDate: DateTime.now().add(const Duration(days: 1)),
        initialDateRange: DateTimeRange(start: _range.start, end: _range.end),
      );
      if (picked == null) return;
      setState(() {
        _preset = RangePreset.custom;
        _range = DateRange(picked.start, picked.end);
      });
    } else {
      setState(() {
        _preset = preset;
        _range = preset == RangePreset.thisMonth
            ? DateRange.thisMonth()
            : DateRange.thisYear();
      });
    }
    widget.onChanged(_range);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).cardColor,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _chip('This Month', RangePreset.thisMonth),
              const SizedBox(width: 8),
              _chip('This Year', RangePreset.thisYear),
              const SizedBox(width: 8),
              _chip('Custom', RangePreset.custom),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${Formatters.dateShort(_range.start)}  —  ${Formatters.dateShort(_range.end)}',
            style: const TextStyle(
                fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, RangePreset preset) {
    final selected = _preset == preset;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => _select(preset),
      labelStyle: TextStyle(
        fontSize: 12,
        color: selected ? Colors.white : AppColors.textPrimary,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
      selectedColor: AppColors.primary,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
    );
  }
}
