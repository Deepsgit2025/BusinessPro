import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../parties/models/party.dart';
import '../../parties/repositories/party_repository.dart';

/// Billing/Supplier name field with an inline type-ahead dropdown of saved
/// parties. As the user types, matching parties (by name or phone) drop down
/// below the field; picking one calls [onPartySelected]. The user can also just
/// type a free-text name that doesn't match any saved party — that's a one-off
/// document party and is reported via [onTextChanged] (with the selected party
/// cleared). No bottom sheet, no forced "add party" step.
class BillingNameField extends StatefulWidget {
  /// 'customer' or 'supplier' — restricts the suggestions.
  final String partyType;

  /// Shared controller holding the current text (the form already owns this).
  final TextEditingController controller;

  final String label;

  /// Called when the user picks a saved party from the dropdown.
  final ValueChanged<Party> onPartySelected;

  /// Called when the user edits the text by hand (typing a free-text name),
  /// which means any previously-selected party should be cleared.
  final ValueChanged<String> onTextChanged;

  const BillingNameField({
    super.key,
    required this.partyType,
    required this.controller,
    required this.label,
    required this.onPartySelected,
    required this.onTextChanged,
  });

  @override
  State<BillingNameField> createState() => _BillingNameFieldState();
}

class _BillingNameFieldState extends State<BillingNameField> {
  final _repo = PartyRepository();
  final _focus = FocusNode();
  List<Party> _all = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadParties();
  }

  Future<void> _loadParties() async {
    final parties = await _repo.getParties(type: widget.partyType);
    if (!mounted) return;
    setState(() {
      _all = parties;
      _loaded = true;
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Iterable<Party> _matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _all.take(20);
    return _all
        .where((p) =>
            p.name.toLowerCase().contains(q) ||
            (p.phone ?? '').toLowerCase().contains(q))
        .take(20);
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Party>(
      textEditingController: widget.controller,
      focusNode: _focus,
      displayStringForOption: (p) => p.name,
      optionsBuilder: (value) => _loaded ? _matches(value.text) : const [],
      onSelected: (p) {
        widget.controller.text = p.name;
        widget.onPartySelected(p);
        _focus.unfocus();
      },
      fieldViewBuilder: (context, controller, focusNode, onSubmit) {
        return TextField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: const Icon(Icons.arrow_drop_down),
          ),
          // Typing by hand means it's a free-text name → clear any picked party.
          onChanged: widget.onTextChanged,
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final list = options.toList();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              // Match the field width via LayoutBuilder upstream isn't trivial
              // here; cap height and let the overlay size to content width.
              constraints: const BoxConstraints(maxHeight: 280, maxWidth: 460),
              child: list.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: Text('No saved parties — keep typing to use this name',
                          style: TextStyle(
                              fontSize: 13, color: AppColors.textSecondary)),
                    )
                  : ListView.separated(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final p = list[i];
                        return ListTile(
                          dense: true,
                          leading: CircleAvatar(
                            radius: 16,
                            backgroundColor:
                                AppColors.primary.withValues(alpha: 0.1),
                            child: Text(
                              p.name.isNotEmpty
                                  ? p.name[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13),
                            ),
                          ),
                          title: Text(p.name,
                              style: const TextStyle(fontSize: 14)),
                          subtitle: (p.phone ?? '').isEmpty
                              ? null
                              : Text(p.phone!,
                                  style: const TextStyle(fontSize: 12)),
                          onTap: () => onSelected(p),
                        );
                      },
                    ),
            ),
          ),
        );
      },
    );
  }
}
