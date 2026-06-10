import 'package:flutter/material.dart';

import 'add_edit_transaction_screen.dart';

/// Estimate / Quotation entry. Same form as a sale invoice but with no payment
/// section (estimate mode). Kept as a named screen so the create sheet and any
/// future estimate-specific tweaks have a clear home.
class EstimateScreen extends StatelessWidget {
  final int? existingId;
  const EstimateScreen({super.key, this.existingId});

  @override
  Widget build(BuildContext context) {
    return AddEditTransactionScreen(
      mode: TxnFormMode.estimate,
      existingId: existingId,
    );
  }
}
