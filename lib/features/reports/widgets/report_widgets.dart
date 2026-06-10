import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../services/report_export_service.dart';

/// An app-bar overflow action offering "Export as PDF" / "Export as CSV". Each
/// report screen builds its [ReportData] lazily via [dataBuilder] so the export
/// always reflects the current filter. Errors surface as a snackbar.
class ReportExportButton extends StatelessWidget {
  final Future<ReportData> Function() dataBuilder;
  const ReportExportButton({super.key, required this.dataBuilder});

  Future<void> _run(BuildContext context, bool pdf) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final data = await dataBuilder();
      if (pdf) {
        await ReportExportService.sharePdf(data);
      } else {
        await ReportExportService.shareCsv(data);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.ios_share),
      tooltip: 'Export',
      onSelected: (v) => _run(context, v == 'pdf'),
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'pdf',
          child: ListTile(
            leading: Icon(Icons.picture_as_pdf_outlined),
            title: Text('Export as PDF'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
        PopupMenuItem(
          value: 'csv',
          child: ListTile(
            leading: Icon(Icons.grid_on_outlined),
            title: Text('Export as CSV'),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
    );
  }
}

/// A horizontal band of labelled metrics shown above a report list (e.g.
/// "Total Sale | Received | Outstanding").
class SummaryBar extends StatelessWidget {
  final List<({String label, String value, Color color})> metrics;
  const SummaryBar({super.key, required this.metrics});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: AppColors.primary.withValues(alpha: 0.06),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        children: [
          for (final m in metrics)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(m.value,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: m.color)),
                  const SizedBox(height: 2),
                  Text(m.label,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Centered empty-state for a report with no rows in the chosen period.
class ReportEmpty extends StatelessWidget {
  final String message;
  const ReportEmpty({super.key, this.message = 'No data for the selected period.'});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bar_chart_outlined,
                size: 56, color: AppColors.textHint),
            const SizedBox(height: 12),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppColors.textSecondary)),
          ],
        ),
      ),
    );
  }
}
