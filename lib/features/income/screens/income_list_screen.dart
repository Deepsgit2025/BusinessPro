import 'package:flutter/material.dart';

import '../../expense/screens/expense_list_screen.dart';

/// Other Income list (drawer → Income). Reuses the expense list screen in income
/// mode — same layout, income categories, and balance-increasing semantics.
class IncomeListScreen extends StatelessWidget {
  const IncomeListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const ExpenseListScreen(isIncome: true);
  }
}
