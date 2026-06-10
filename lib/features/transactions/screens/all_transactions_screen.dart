import 'package:flutter/material.dart';
import '../../../core/constants/app_colors.dart';
import '../../../core/utils/formatters.dart';
import '../../parties/models/party.dart';
import '../../parties/repositories/party_repository.dart';
import '../models/transaction.dart';
import '../repositories/transaction_repository.dart';
import 'sale_detail_screen.dart';

// ── Filter state ──────────────────────────────────────────────────────────────

class _Filter {
  final DateTime from;
  final DateTime to;
  final String? txnType; // null = all
  final int? partyId;
  final String? partyName;
  final _Period period;

  const _Filter({
    required this.from,
    required this.to,
    this.txnType,
    this.partyId,
    this.partyName,
    this.period = _Period.thisMonth,
  });

  _Filter copyWith({
    DateTime? from,
    DateTime? to,
    _Period? period,
    Object? txnType = _sentinel,
    Object? partyId = _sentinel,
    Object? partyName = _sentinel,
  }) =>
      _Filter(
        from: from ?? this.from,
        to: to ?? this.to,
        period: period ?? this.period,
        txnType: txnType == _sentinel ? this.txnType : txnType as String?,
        partyId: partyId == _sentinel ? this.partyId : partyId as int?,
        partyName:
            partyName == _sentinel ? this.partyName : partyName as String?,
      );

  static const _sentinel = Object();
}

// ── Period (timeframe) presets ─────────────────────────────────────────────────

enum _Period { thisWeek, thisMonth, thisQuarter, thisFinancialYear, custom }

const _periodLabels = <_Period, String>{
  _Period.thisWeek: 'This week',
  _Period.thisMonth: 'This month',
  _Period.thisQuarter: 'This quarter',
  _Period.thisFinancialYear: 'This financial year',
  _Period.custom: 'Custom',
};

/// Returns the [from, to] date range for a preset period, anchored on [now].
/// Financial year follows the Indian convention (Apr 1 – Mar 31).
(DateTime, DateTime) _rangeForPeriod(_Period period, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  switch (period) {
    case _Period.thisWeek:
      final start = today.subtract(Duration(days: today.weekday - 1));
      return (start, start.add(const Duration(days: 6)));
    case _Period.thisMonth:
      return (
        DateTime(now.year, now.month, 1),
        DateTime(now.year, now.month + 1, 0),
      );
    case _Period.thisQuarter:
      final qStartMonth = ((now.month - 1) ~/ 3) * 3 + 1;
      return (
        DateTime(now.year, qStartMonth, 1),
        DateTime(now.year, qStartMonth + 3, 0),
      );
    case _Period.thisFinancialYear:
      final fyStartYear = now.month >= 4 ? now.year : now.year - 1;
      return (
        DateTime(fyStartYear, 4, 1),
        DateTime(fyStartYear + 1, 3, 31),
      );
    case _Period.custom:
      return (today, today);
  }
}

// ── Type dropdown config ──────────────────────────────────────────────────────

const _txnTypeLabels = <String?, String>{
  null: 'All Transactions',
  TxnTypes.sale: 'Sale Invoice',
  TxnTypes.paymentIn: 'Payment-In',
  TxnTypes.saleReturn: 'Credit Note',
  TxnTypes.estimate: 'Estimate',
  TxnTypes.saleOrder: 'Sale Order',
  TxnTypes.deliveryChallan: 'Delivery Challan',
  TxnTypes.purchase: 'Purchase',
  TxnTypes.purchaseReturn: 'Purchase Return',
  TxnTypes.expense: 'Expense',
  TxnTypes.otherIncome: 'Other Income',
  TxnTypes.paymentOut: 'Payment-Out',
};

// ── Screen ────────────────────────────────────────────────────────────────────

class AllTransactionsScreen extends StatefulWidget {
  /// When set, the type dropdown is hidden and the list is locked to this
  /// single transaction type (e.g. Payment-In).
  final String? lockedTxnType;

  /// Optional title override (defaults to 'All Transactions').
  final String? title;

  /// When set, a bottom "Add" bar is shown. Returning `true` from [onAdd]
  /// (i.e. something was created) triggers a reload of the list.
  final String? addLabel;
  final Future<bool?> Function(BuildContext context)? onAdd;

  const AllTransactionsScreen({
    super.key,
    this.lockedTxnType,
    this.title,
    this.addLabel,
    this.onAdd,
  });

  @override
  State<AllTransactionsScreen> createState() => _AllTransactionsScreenState();
}

class _AllTransactionsScreenState extends State<AllTransactionsScreen> {
  final _repo = TransactionRepository();
  final _partyRepo = PartyRepository();

  late _Filter _filter;
  List<Transaction> _txns = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    final (from, to) = _rangeForPeriod(_Period.thisMonth, now);
    _filter = _Filter(
      from: from,
      to: to,
      txnType: widget.lockedTxnType,
    );
    _load();
  }

  Future<void> _pickPeriod() async {
    final selected = await showModalBottomSheet<_Period>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: _periodLabels.entries
              .where((e) => e.key != _Period.custom)
              .map((e) => ListTile(
                    title: Text(e.value),
                    trailing: _filter.period == e.key
                        ? const Icon(Icons.check, color: AppColors.primary)
                        : null,
                    onTap: () => Navigator.pop(context, e.key),
                  ))
              .toList(),
        ),
      ),
    );
    if (selected == null) return;
    final (from, to) = _rangeForPeriod(selected, DateTime.now());
    setState(() =>
        _filter = _filter.copyWith(period: selected, from: from, to: to));
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final types = _filter.txnType == null
        ? _txnTypeLabels.keys.whereType<String>().toList()
        : [_filter.txnType!];
    final all = await _repo.list(types);
    final filtered = all.where((t) {
      final d = DateTime.tryParse(t.transactionDate);
      if (d == null) return false;
      final inRange =
          !d.isBefore(_filter.from) && !d.isAfter(_filter.to.add(const Duration(days: 1)));
      final partyMatch =
          _filter.partyId == null || t.partyId == _filter.partyId;
      return inRange && partyMatch;
    }).toList();
    if (mounted) setState(() { _txns = filtered; _loading = false; });
  }

  Future<void> _pickDateRange() async {
    final range = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange:
          DateTimeRange(start: _filter.from, end: _filter.to),
    );
    if (range != null) {
      setState(() => _filter = _filter.copyWith(
          from: range.start, to: range.end, period: _Period.custom));
      _load();
    }
  }

  Future<void> _pickParty() async {
    final parties = await _partyRepo.getParties();
    if (!mounted) return;
    final picked = await showModalBottomSheet<Party>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PartyFilterSheet(parties: parties),
    );
    if (picked == null) return;
    setState(() => _filter = _filter.copyWith(
        partyId: picked.id, partyName: picked.name));
    _load();
  }

  void _clearParty() {
    setState(() => _filter =
        _filter.copyWith(partyId: null, partyName: null));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F5F5),
      bottomNavigationBar: (widget.addLabel != null && widget.onAdd != null)
          ? _AddBottomBar(
              label: widget.addLabel!,
              onPressed: () async {
                final created = await widget.onAdd!(context);
                if (created == true) _load();
              },
            )
          : null,
      appBar: AppBar(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(widget.title ?? 'All Transactions',
            style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(icon: const Icon(Icons.picture_as_pdf_outlined), onPressed: () {}),
          IconButton(icon: const Icon(Icons.table_chart_outlined), onPressed: () {}),
        ],
      ),
      body: Column(
        children: [
          // ── Date range row ───────────────────────────────────────────────
          Container(
            color: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _PeriodChip(
                  label: _periodLabels[_filter.period] ?? 'Custom',
                  onTap: _pickPeriod,
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: _pickDateRange,
                  child: Row(
                    children: [
                      const Icon(Icons.calendar_today_outlined,
                          size: 16, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text(Formatters.date(_filter.from.toIso8601String()),
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w500)),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 6),
                        child: Text('to',
                            style: TextStyle(
                                fontSize: 13,
                                color: AppColors.textSecondary)),
                      ),
                      Text(Formatters.date(_filter.to.toIso8601String()),
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textPrimary,
                              fontWeight: FontWeight.w500)),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),

          // ── Type dropdown (hidden when locked to a single type) ──────────
          if (widget.lockedTxnType == null) ...[
            Container(
              color: Colors.white,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButton<String?>(
                      value: _filter.txnType,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      icon: const Icon(Icons.arrow_drop_down),
                      style: const TextStyle(
                          fontSize: 14,
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w500),
                      items: _txnTypeLabels.entries
                          .map((e) => DropdownMenuItem<String?>(
                              value: e.key, child: Text(e.value)))
                          .toList(),
                      onChanged: (v) {
                        setState(() => _filter = _filter.copyWith(txnType: v));
                        _load();
                      },
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: AppColors.divider),
          ],

          // ── Party filter ─────────────────────────────────────────────────
          Container(
            color: Colors.white,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Text('Party Name',
                    style: TextStyle(
                        fontSize: 13,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: GestureDetector(
                    onTap: _pickParty,
                    child: Row(
                      children: [
                        Text(
                          _filter.partyName ?? 'All parties',
                          style: const TextStyle(
                              fontSize: 13,
                              color: AppColors.textSecondary),
                        ),
                        const Spacer(),
                        if (_filter.partyId != null)
                          GestureDetector(
                            onTap: _clearParty,
                            child: const Icon(Icons.close,
                                size: 16, color: AppColors.textSecondary),
                          )
                        else
                          const Icon(Icons.arrow_drop_down,
                              color: AppColors.textSecondary),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.divider),

          // ── Transaction list ─────────────────────────────────────────────
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _txns.isEmpty
                    ? const Center(
                        child: Text('No transactions found',
                            style: TextStyle(
                                color: AppColors.textSecondary)))
                    : ListView.separated(
                        padding: EdgeInsets.zero,
                        itemCount: _txns.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (context, i) {
                          final t = _txns[i];
                          return _TxnRow(
                            txn: t,
                            onTap: () async {
                              await Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (_) =>
                                      SaleDetailScreen(transactionId: t.id!),
                                ),
                              );
                              _load();
                            },
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ── Period chip ───────────────────────────────────────────────────────────────

class _PeriodChip extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _PeriodChip({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppColors.backgroundLight,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 12, color: AppColors.textPrimary)),
            const SizedBox(width: 4),
            const Icon(Icons.arrow_drop_down,
                size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

// ── Transaction row ───────────────────────────────────────────────────────────

class _TxnRow extends StatelessWidget {
  final Transaction txn;
  final VoidCallback onTap;
  const _TxnRow({required this.txn, required this.onTap});

  String get _typeLabel =>
      _txnTypeLabels[txn.transactionType] ?? txn.transactionType;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: Colors.white,
        padding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(txn.partyName ?? '—',
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary)),
                  const SizedBox(height: 2),
                  Text(
                      Formatters.date(txn.transactionDate),
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${_typeLabel.split(' ').first} : ${txn.transactionNumber}',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 2),
                Text('Total : ${Formatters.currency(txn.totalAmount)}',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary)),
                if (txn.balanceAmount > 0)
                  Text('Balance : ${Formatters.currency(txn.balanceAmount)}',
                      style: const TextStyle(
                          fontSize: 12, color: AppColors.expense)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ── Bottom "Add" bar ──────────────────────────────────────────────────────────

class _AddBottomBar extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  const _AddBottomBar({required this.label, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            onPressed: onPressed,
            icon: const Icon(Icons.add_circle, size: 22),
            label: Text(label,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.expense,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Party filter bottom sheet ─────────────────────────────────────────────────

class _PartyFilterSheet extends StatefulWidget {
  final List<Party> parties;
  const _PartyFilterSheet({required this.parties});

  @override
  State<_PartyFilterSheet> createState() => _PartyFilterSheetState();
}

class _PartyFilterSheetState extends State<_PartyFilterSheet> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final filtered = widget.parties
        .where((p) =>
            p.name.toLowerCase().contains(_search.toLowerCase()))
        .toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (_, ctrl) => Column(
        children: [
          const SizedBox(height: 8),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
                color: AppColors.border,
                borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'Search party…',
                prefixIcon: Icon(Icons.search),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _search = v),
            ),
          ),
          Expanded(
            child: ListView.separated(
              controller: ctrl,
              itemCount: filtered.length,
              separatorBuilder: (_, _) =>
                  const Divider(height: 1, color: AppColors.divider),
              itemBuilder: (_, i) {
                final p = filtered[i];
                return ListTile(
                  title: Text(p.name),
                  subtitle:
                      p.phone != null ? Text(p.phone!) : null,
                  onTap: () => Navigator.pop(context, p),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
