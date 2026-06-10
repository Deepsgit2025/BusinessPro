import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../widgets/report_card_widget.dart';
import 'day_book_screen.dart';
import 'expense_report_screen.dart';
import 'low_stock_screen.dart';
import 'outstanding_screen.dart';
import 'party_statement_screen.dart';
import 'profit_loss_screen.dart';
import 'sale_purchase_report_screen.dart';
import 'stock_summary_screen.dart';

/// Reports home (drawer → Reports). A 2-column grid of report cards. Tapping a
/// card opens that report; each report carries its own date filter and export.
class ReportsHomeScreen extends StatelessWidget {
  const ReportsHomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final cards = <_ReportDef>[
      _ReportDef(Icons.today_outlined, AppColors.primary, 'Day Book',
          (c) => const DayBookScreen()),
      _ReportDef(Icons.point_of_sale_outlined, AppColors.income, 'Sale Report',
          (c) => const SalePurchaseReportScreen(isPurchase: false)),
      _ReportDef(Icons.shopping_cart_outlined, AppColors.partial,
          'Purchase\nReport',
          (c) => const SalePurchaseReportScreen(isPurchase: true)),
      _ReportDef(Icons.trending_up, AppColors.accent, 'Profit &\nLoss',
          (c) => const ProfitLossScreen()),
      _ReportDef(Icons.receipt_long_outlined, AppColors.primaryDark,
          'Party\nStatement',
          (c) => const PartyStatementScreen()),
      _ReportDef(Icons.call_received, AppColors.income,
          'Receivables',
          (c) => const OutstandingScreen(isPayable: false)),
      _ReportDef(Icons.call_made, AppColors.expense, 'Payables',
          (c) => const OutstandingScreen(isPayable: true)),
      _ReportDef(Icons.inventory_2_outlined, AppColors.partial, 'Stock\nSummary',
          (c) => const StockSummaryScreen()),
      _ReportDef(Icons.pie_chart_outline, AppColors.pending, 'Expense\nReport',
          (c) => const ExpenseReportScreen()),
      _ReportDef(Icons.warning_amber_outlined, AppColors.expense,
          'Low Stock',
          (c) => const LowStockScreen()),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(12, 14, 12, 10),
        alignment: Alignment.topCenter,
        child: GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            mainAxisExtent: 96,
            mainAxisSpacing: 4,
          ),
          itemCount: cards.length,
          itemBuilder: (context, i) => ReportCardWidget(
            icon: cards[i].icon,
            color: cards[i].color,
            title: cards[i].title,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: cards[i].builder),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReportDef {
  final IconData icon;
  final Color color;
  final String title;
  final WidgetBuilder builder;
  _ReportDef(this.icon, this.color, this.title, this.builder);
}
