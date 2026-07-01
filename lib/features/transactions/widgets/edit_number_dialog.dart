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
  final result = await showDialog<String>(
    context: context,
    builder: (_) => _EditNumberDialog(
      label: label,
      current: current,
      repo: repo,
      excludeId: excludeId,
    ),
  );
  if (result == null) return null;
  final trimmed = result.trim();
  if (trimmed.isEmpty || trimmed == current) return null;
  return trimmed;
}

/// The dialog body. Owns its own [TextEditingController] and disposes it in
/// [dispose] — i.e. only after the dialog route has been removed and its exit
/// transition finished. Disposing the controller synchronously right after
/// `await showDialog` (the previous approach) crashed on Android with
/// "A TextEditingController was used after being disposed", because the
/// TextField was still mounted during the pop animation.
class _EditNumberDialog extends StatefulWidget {
  final String label;
  final String current;
  final TransactionRepository repo;
  final int? excludeId;

  const _EditNumberDialog({
    required this.label,
    required this.current,
    required this.repo,
    required this.excludeId,
  });

  @override
  State<_EditNumberDialog> createState() => _EditNumberDialogState();
}

class _EditNumberDialogState extends State<_EditNumberDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.current);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final entered = _controller.text.trim();
    if (entered.isEmpty) {
      setState(() => _error = 'Number cannot be empty');
      return;
    }
    if (entered != widget.current) {
      final clash =
          await widget.repo.numberExists(entered, excludeId: widget.excludeId);
      if (!mounted) return;
      if (clash) {
        setState(() => _error = 'That number is already used');
        return;
      }
    }
    if (mounted) Navigator.pop(context, entered);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Edit ${widget.label}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: 'e.g. K/100',
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
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
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
