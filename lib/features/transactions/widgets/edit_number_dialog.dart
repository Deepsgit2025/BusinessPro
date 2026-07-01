import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../repositories/transaction_repository.dart';

/// Shows a dialog to override a document number (invoice / estimate / challan /
/// return / receipt). Returns the new trimmed number, or `null` if the user
/// cancelled or left it unchanged.
///
/// The override is meant to apply to the single document being created/edited;
/// callers keep the running counter untouched when the value differs from the
/// auto-generated one. The dialog validates the number is non-empty and not
/// already used by another (non-deleted) document — [excludeId] skips the row
/// being edited so re-saving its own number isn't flagged.
Future<String?> editDocumentNumber(
  BuildContext context, {
  required String label,
  required String current,
  required TransactionRepository repo,
  int? excludeId,
}) async {
  final controller = TextEditingController(text: current);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) {
      String? error;
      return StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text('Edit $label'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  labelText: label,
                  hintText: 'e.g. K/100',
                  border: const OutlineInputBorder(),
                  errorText: error,
                ),
                onChanged: (_) {
                  if (error != null) setLocal(() => error = null);
                },
                onSubmitted: (_) => Navigator.pop(ctx, controller.text),
              ),
              const SizedBox(height: 8),
              const Text(
                'Applies to this document only. The next one keeps the normal '
                'sequence.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                final entered = controller.text.trim();
                if (entered.isEmpty) {
                  setLocal(() => error = 'Number cannot be empty');
                  return;
                }
                if (entered != current) {
                  final clash =
                      await repo.numberExists(entered, excludeId: excludeId);
                  if (clash) {
                    setLocal(() => error = 'That number is already used');
                    return;
                  }
                }
                if (ctx.mounted) Navigator.pop(ctx, entered);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
    },
  );
  controller.dispose();
  if (result == null) return null;
  final trimmed = result.trim();
  if (trimmed.isEmpty || trimmed == current) return null;
  return trimmed;
}
