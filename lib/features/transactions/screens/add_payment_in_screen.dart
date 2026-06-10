import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/formatters.dart';
import '../../parties/models/party.dart';
import '../../parties/repositories/party_repository.dart';
import '../models/payment.dart';
import '../models/transaction.dart';
import '../providers/transaction_providers.dart';
import '../services/invoice_pdf_service.dart';
import '../services/transaction_share_service.dart';
import '../widgets/party_picker.dart';

class AddPaymentInScreen extends ConsumerStatefulWidget {
  const AddPaymentInScreen({super.key});

  @override
  ConsumerState<AddPaymentInScreen> createState() => _AddPaymentInScreenState();
}

class _AddPaymentInScreenState extends ConsumerState<AddPaymentInScreen> {
  final _amountCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();

  String _receiptNumber = '';
  DateTime _date = DateTime.now();
  Party? _party;
  double _partyBalance = 0;
  int? _paymentModeId;
  int? _accountId;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _receiptNumber = await DatabaseHelper.peekReceiptNumber();
    if (mounted) setState(() => _loading = false);
  }

  @override
  void dispose() {
    _amountCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickParty() async {
    final picked = await showPartyPicker(context, type: 'customer');
    if (picked == null) return;
    final full = await PartyRepository().getById(picked.id!);
    setState(() {
      _party = full ?? picked;
      _partyBalance = (full ?? picked).netBalance;
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date = picked);
  }

  /// Persists the payment and returns its saved row id, or `null` if validation
  /// failed or the save errored. Pass [pop] = false to stay on the screen (used
  /// by the share/print actions which act on the saved record).
  Future<int?> _save({bool pop = true}) async {
    final amount = double.tryParse(_amountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      _snack('Enter a valid amount');
      return null;
    }
    setState(() => _saving = true);

    final receiptNum = await DatabaseHelper.nextReceiptNumber();
    final repo = ref.read(transactionRepositoryProvider);

    final txn = Transaction(
      partyId: _party?.id,
      accountId: _accountId,
      transactionType: TxnTypes.paymentIn,
      transactionNumber: receiptNum,
      transactionDate: _date.toIso8601String(),
      totalAmount: amount,
      notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    );

    final payment = Payment(
      accountId: _accountId,
      paymentModeId: _paymentModeId,
      amount: amount,
      paymentDate: _date.toIso8601String(),
    );

    try {
      final id = await repo.createCashTransaction(txn, payment: payment);
      ref.refreshTransactions();
      if (!mounted) return null;
      _snack('Payment-In saved');
      if (pop) {
        Navigator.pop(context, true);
      } else {
        setState(() => _saving = false);
      }
      return id;
    } catch (e) {
      if (!mounted) return null;
      setState(() => _saving = false);
      _snack('Could not save: $e');
      return null;
    }
  }

  // ── Share / Print (top-bar actions) ─────────────────────────────────────────

  Future<Uint8List> _buildPdf(int transactionId) async {
    final repo = ref.read(transactionRepositoryProvider);
    final txn = await repo.getById(transactionId);
    final items = await repo.getItems(transactionId);
    if (txn == null) {
      throw StateError('Saved payment $transactionId could not be loaded');
    }
    return InvoicePdfService.build(transaction: txn, items: items);
  }

  /// Saves the receipt (without leaving the screen) and opens the
  /// "Share transaction" chooser (Image / PDF).
  Future<void> _saveAndShare() async {
    if (_saving) return;
    final id = await _save(pop: false);
    if (id == null || !mounted) return;
    try {
      final repo = ref.read(transactionRepositoryProvider);
      final txn = await repo.getById(id);
      final items = await repo.getItems(id);
      if (txn == null || !mounted) return;
      await TransactionShareService.share(
        context: context,
        transaction: txn,
        items: items,
      );
    } catch (e) {
      if (mounted) _snack('Could not share: $e');
    }
  }

  /// Saves the receipt (without leaving the screen) and opens the print dialog.
  Future<void> _saveAndPrint() async {
    if (_saving) return;
    final id = await _save(pop: false);
    if (id == null || !mounted) return;
    try {
      await Printing.layoutPdf(onLayout: (_) => _buildPdf(id));
    } catch (e) {
      if (mounted) _snack('Could not print: $e');
    }
  }

  Widget _overflowMenu() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'More',
      onSelected: (v) async {
        switch (v) {
          case 'share':
            await _saveAndShare();
          case 'print':
            await _saveAndPrint();
          case 'settings':
            break;
        }
      },
      itemBuilder: (_) => const [
        PopupMenuItem(
          value: 'share',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.share_outlined),
            title: Text('Share'),
          ),
        ),
        PopupMenuItem(
          value: 'print',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.print_outlined),
            title: Text('Print'),
          ),
        ),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'settings',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.settings_outlined),
            title: Text('Settings'),
          ),
        ),
      ],
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final modes = ref.watch(paymentModesProvider);
    final accounts = ref.watch(accountsProvider);

    return Scaffold(
      backgroundColor: AppColors.surface(context),
      appBar: AppBar(
        backgroundColor: AppColors.surface(context),
        foregroundColor: AppColors.textPrimaryOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: AppColors.dividerOf(context))),
        title: const Text('Payment-In',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share',
            onPressed: _saving ? null : _saveAndShare,
          ),
          _overflowMenu(),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: [
                // ── Receipt No. + Date header ──────────────────────────────
                Container(
                  color: AppColors.surface(context),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: _HeaderField(
                          label: 'Receipt No.',
                          value: _receiptNumber,
                          icon: Icons.expand_more,
                        ),
                      ),
                      Container(
                          width: 1, height: 36, color: AppColors.dividerOf(context)),
                      Expanded(
                        child: GestureDetector(
                          onTap: _pickDate,
                          child: _HeaderField(
                            label: 'Date',
                            value: Formatters.date(_date.toIso8601String()),
                            icon: Icons.expand_more,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: AppColors.dividerOf(context)),

                // ── Party Balance ──────────────────────────────────────────
                Container(
                  color: AppColors.surface(context),
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'Party Balance: ${Formatters.currency(_partyBalance)}',
                      style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.expense,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ),

                // ── Customer Name ──────────────────────────────────────────
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: GestureDetector(
                    onTap: _pickParty,
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.dividerOf(context)),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 14),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _party?.name ?? 'Customer Name',
                              style: TextStyle(
                                fontSize: 15,
                                color: _party == null
                                    ? AppColors.textHint
                                    : AppColors.textPrimaryOf(context),
                              ),
                            ),
                          ),
                          const Icon(Icons.chevron_right,
                              color: AppColors.textHint),
                        ],
                      ),
                    ),
                  ),
                ),

                const SizedBox(height: 4),
                Divider(height: 1, color: AppColors.dividerOf(context)),

                // ── Received + Total Amount ────────────────────────────────
                Container(
                  color: AppColors.background(context),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Text('Received',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimaryOf(context))),
                          const Spacer(),
                          const Text('₹',
                              style: TextStyle(
                                  fontSize: 16,
                                  color: AppColors.textSecondary)),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 140,
                            child: TextField(
                              controller: _amountCtrl,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                      decimal: true),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                    RegExp(r'^\d*\.?\d*')),
                              ],
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.textPrimaryOf(context)),
                              decoration: const InputDecoration(
                                border: UnderlineInputBorder(
                                  borderSide: BorderSide(
                                      color: AppColors.primary, width: 2),
                                ),
                                enabledBorder: UnderlineInputBorder(
                                  borderSide: BorderSide(
                                      color: AppColors.primary, width: 2),
                                ),
                                focusedBorder: UnderlineInputBorder(
                                  borderSide: BorderSide(
                                      color: AppColors.primary, width: 2),
                                ),
                                isDense: true,
                                contentPadding:
                                    EdgeInsets.only(bottom: 4),
                              ),
                              onChanged: (v) => setState(() {}),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          const Text('Total Amount',
                              style: TextStyle(
                                  fontSize: 15,
                                  color: AppColors.primary,
                                  fontWeight: FontWeight.w500)),
                          const Spacer(),
                          const Text('₹',
                              style: TextStyle(
                                  fontSize: 15, color: AppColors.primary)),
                          const SizedBox(width: 4),
                          Text(
                            (double.tryParse(_amountCtrl.text.trim()) ?? 0)
                                .toStringAsFixed(2),
                            style: const TextStyle(
                                fontSize: 15,
                                color: AppColors.primary,
                                fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                Divider(height: 1, color: AppColors.dividerOf(context)),

                // ── Payment Type ───────────────────────────────────────────
                modes.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (list) {
                    _paymentModeId ??=
                        list.where((m) => m.type == 'cash').firstOrNull?.id ??
                            list.firstOrNull?.id;
                    return Container(
                      color: AppColors.surface(context),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          Text('Payment Type',
                              style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.textPrimaryOf(context))),
                          const Spacer(),
                          DropdownButton<int>(
                            value: _paymentModeId,
                            underline: const SizedBox.shrink(),
                            icon: const Icon(Icons.expand_more),
                            items: list
                                .map((m) => DropdownMenuItem(
                                    value: m.id, child: Text(m.name)))
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _paymentModeId = v),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                accounts.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                  data: (list) {
                    _accountId ??=
                        list.where((a) => a.isDefault).firstOrNull?.id ??
                            list.firstOrNull?.id;
                    return Container(
                      color: AppColors.surface(context),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Row(
                        children: [
                          Text('Deposit To',
                              style: TextStyle(
                                  fontSize: 14,
                                  color: AppColors.textPrimaryOf(context))),
                          const Spacer(),
                          DropdownButton<int>(
                            value: _accountId,
                            underline: const SizedBox.shrink(),
                            icon: const Icon(Icons.expand_more),
                            items: list
                                .map((a) => DropdownMenuItem(
                                    value: a.id, child: Text(a.name)))
                                .toList(),
                            onChanged: (v) =>
                                setState(() => _accountId = v),
                          ),
                        ],
                      ),
                    );
                  },
                ),

                Divider(height: 1, color: AppColors.dividerOf(context)),

                // ── Description / Note ─────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: TextField(
                    controller: _notesCtrl,
                    maxLines: 3,
                    decoration: InputDecoration(
                      hintText: 'Add Note',
                      hintStyle:
                          const TextStyle(color: AppColors.textHint),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              BorderSide(color: AppColors.dividerOf(context))),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide:
                              BorderSide(color: AppColors.dividerOf(context))),
                    ),
                  ),
                ),
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Save & New'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _saving ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderField extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  const _HeaderField(
      {required this.label, required this.value, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        fontSize: 11, color: AppColors.textSecondary)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
              ],
            ),
          ),
          Icon(icon, size: 18, color: AppColors.textSecondary),
        ],
      ),
    );
  }
}
