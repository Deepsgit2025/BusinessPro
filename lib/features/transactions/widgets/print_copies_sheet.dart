import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../services/invoice_pdf_service.dart';

/// Copy-selection sheet for printing a 3-copy sale invoice (Invoice Format 1).
/// All three copies are checked by default; the user can uncheck any. Pops with
/// the chosen labels in canonical order (or null if dismissed).
///
/// Shared by the add/edit transaction screen and the saved sale detail screen.
class PrintCopiesSheet extends StatefulWidget {
  const PrintCopiesSheet({super.key});

  /// Shows the sheet and returns the chosen copy labels in canonical order, or
  /// null if the user dismisses it.
  static Future<List<String>?> show(BuildContext context) {
    return showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: AppColors.surface(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => const PrintCopiesSheet(),
    );
  }

  @override
  State<PrintCopiesSheet> createState() => _PrintCopiesSheetState();
}

class _PrintCopiesSheetState extends State<PrintCopiesSheet> {
  // One checked-flag per canonical copy label, all on by default.
  final _checked = {for (final l in InvoicePdfService.copyLabels) l: true};

  static String _pretty(String label) => switch (label) {
        'ORIGINAL FOR RECIPIENT' => 'Original for Recipient',
        'DUPLICATE FOR TRANSPORTER' => 'Duplicate for Transporter',
        'OFFICE COPY' => 'Office Copy',
        _ => label,
      };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Print Invoice',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Copies to print:',
                style: TextStyle(color: AppColors.textSecondary)),
            const SizedBox(height: 8),
            for (final label in InvoicePdfService.copyLabels)
              CheckboxListTile(
                value: _checked[label],
                onChanged: (v) => setState(() => _checked[label] = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(_pretty(label)),
              ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.partial,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () {
                  final selected = InvoicePdfService.copyLabels
                      .where((l) => _checked[l] == true)
                      .toList();
                  Navigator.pop(context, selected);
                },
                child: const Text('Print Selected',
                    style:
                        TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
