import 'package:flutter/material.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../parties/models/party.dart';
import '../../transactions/widgets/party_picker.dart';
import '../models/report_models.dart';
import '../repositories/reports_repository.dart';
import '../services/report_export_service.dart';
import '../widgets/report_widgets.dart';

/// Report 5 — Party Statement. Pick a party, then see their full running ledger
/// (opening balance first, then each transaction with a debit/credit and a
/// running balance column).
class PartyStatementScreen extends StatefulWidget {
  const PartyStatementScreen({super.key});

  @override
  State<PartyStatementScreen> createState() => _PartyStatementScreenState();
}

class _PartyStatementScreenState extends State<PartyStatementScreen> {
  final _repo = ReportsRepository();
  Party? _party;
  Future<List<StatementRow>>? _future;

  Future<void> _pickParty() async {
    // type 'all' isn't a filter branch in the picker, so it lists every party.
    final p = await showPartyPicker(context, type: 'all');
    if (p != null && p.id != null) {
      setState(() {
        _party = p;
        _future = _repo.partyStatement(p.id!);
      });
    }
  }

  Future<ReportData> _buildExport(List<StatementRow> rows) async {
    return ReportData(
      title: 'Party Statement — ${_party?.name ?? ''}',
      subtitle: _party?.phone ?? '',
      headers: const ['Date', 'Particulars', 'Debit', 'Credit', 'Balance'],
      rightAlign: const [false, false, true, true, true],
      rows: [
        for (final r in rows)
          [
            r.date.isEmpty ? '-' : Formatters.date(r.date),
            r.number,
            r.debit == 0 ? '-' : Formatters.currency(r.debit),
            r.credit == 0 ? '-' : Formatters.currency(r.credit),
            Formatters.currency(r.runningBalance),
          ],
      ],
      summary: [
        if (rows.isNotEmpty)
          MapEntry('Closing Balance',
              Formatters.currency(rows.last.runningBalance)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Party Statement'),
        actions: [
          if (_future != null)
            ReportExportButton(
              dataBuilder: () async => _buildExport(await _future!),
            ),
        ],
      ),
      body: Column(
        children: [
          InkWell(
            onTap: _pickParty,
            child: Container(
              color: Theme.of(context).cardColor,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  const Icon(Icons.person_outline,
                      size: 20, color: AppColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _party?.name ?? 'Select a party',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _party == null
                              ? AppColors.textSecondary
                              : AppColors.textPrimary),
                    ),
                  ),
                  const Text('Change',
                      style: TextStyle(color: AppColors.primary)),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _future == null
                ? const ReportEmpty(message: 'Pick a party to see their ledger.')
                : FutureBuilder<List<StatementRow>>(
                    future: _future,
                    builder: (context, snap) {
                      if (!snap.hasData) {
                        return const Center(
                            child: CircularProgressIndicator());
                      }
                      final rows = snap.data!;
                      if (rows.isEmpty) {
                        return const ReportEmpty(
                            message: 'No transactions for this party.');
                      }
                      return Column(
                        children: [
                          _headerRow(),
                          const Divider(height: 1),
                          Expanded(
                            child: ListView.separated(
                              itemCount: rows.length,
                              separatorBuilder: (_, _) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) => _ledgerRow(rows[i]),
                            ),
                          ),
                          _closingRow(rows.last.runningBalance),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _headerRow() {
    return Container(
      color: AppColors.primary.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: const Row(
        children: [
          Expanded(flex: 4, child: Text('Particulars',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          Expanded(flex: 2, child: Text('Debit', textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          Expanded(flex: 2, child: Text('Credit', textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
          Expanded(flex: 3, child: Text('Balance', textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }

  Widget _ledgerRow(StatementRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.number,
                    style: const TextStyle(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                if (r.date.isNotEmpty)
                  Text(Formatters.date(r.date),
                      style: const TextStyle(
                          fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(r.debit == 0 ? '-' : Formatters.currency(r.debit),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            flex: 2,
            child: Text(r.credit == 0 ? '-' : Formatters.currency(r.credit),
                textAlign: TextAlign.right,
                style: const TextStyle(fontSize: 12)),
          ),
          Expanded(
            flex: 3,
            child: Text(Formatters.currency(r.runningBalance),
                textAlign: TextAlign.right,
                style: const TextStyle(
                    fontSize: 12, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _closingRow(double balance) {
    return Container(
      width: double.infinity,
      color: AppColors.primary.withValues(alpha: 0.06),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Closing Balance',
              style: TextStyle(fontWeight: FontWeight.w700)),
          Text(Formatters.currency(balance),
              style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: balance >= 0 ? AppColors.income : AppColors.expense)),
        ],
      ),
    );
  }
}
