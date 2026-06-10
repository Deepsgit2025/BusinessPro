import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:printing/printing.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_lists.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/formatters.dart';
import '../../items/models/item_unit.dart';
import '../../items/models/tax_rate.dart';
import '../../items/repositories/item_unit_repository.dart';
import '../../items/repositories/tax_rate_repository.dart';
import '../../parties/models/party.dart';
import '../../parties/repositories/party_repository.dart';
import '../models/payment.dart';
import '../models/transaction.dart';
import '../models/transaction_item.dart';
import '../providers/transaction_providers.dart';
import '../services/invoice_pdf_service.dart';
import '../services/transaction_share_service.dart';
import '../utils/txn_calc.dart';
import '../widgets/item_line_widget.dart';
import '../widgets/item_picker.dart';
import '../widgets/line_draft.dart';
import '../widgets/party_picker.dart';
import '../widgets/totals_section.dart';

/// Shared entry screen for sale / purchase / estimate. Configured by [mode].
///
/// Pass [existingId] to edit (only allowed before any payment exists). The
/// screen owns a list of [LineDraft]s, recomputes totals on every change via
/// [TxnCalc], and writes everything atomically on save.
enum TxnFormMode {
  sale,
  purchase,
  estimate,
  saleReturn,
  saleOrder,
  deliveryChallan,
  paymentIn,
  purchaseReturn,
  purchaseOrder,
  paymentOut,
}

class AddEditTransactionScreen extends ConsumerStatefulWidget {
  final TxnFormMode mode;
  final int? existingId;

  /// When set, the form is pre-filled from this transaction's party / lines /
  /// notes but saved as a brand-new document (fresh number, no [existingId]).
  /// Used by the detail screen's "Duplicate" action.
  final int? duplicateFromId;

  const AddEditTransactionScreen({
    super.key,
    required this.mode,
    this.existingId,
    this.duplicateFromId,
  });

  @override
  ConsumerState<AddEditTransactionScreen> createState() =>
      _AddEditTransactionScreenState();
}

class _AddEditTransactionScreenState
    extends ConsumerState<AddEditTransactionScreen> {
  final _itemUnitRepo = ItemUnitRepository();
  final _taxRepo = TaxRateRepository();

  // Master / context data.
  List<TaxRate> _taxRates = [];
  String? _businessState;
  bool _loading = true;
  bool _saving = false;

  // Form state.
  Party? _party;
  final List<LineDraft> _lines = [];
  DateTime _date = DateTime.now();
  DateTime? _dueDate;
  final _notes = TextEditingController();
  final _reference = TextEditingController();
  final _billingName = TextEditingController();
  final _phone = TextEditingController();

  // Credit Note (sale return) only: a manually-entered total + amount paid,
  // used when the note is recorded as a flat amount without line items.
  final _manualTotal = TextEditingController();
  final _manualPaid = TextEditingController();

  /// Credit Note only: date of the original invoice being returned against.
  DateTime? _invoiceDate;

  /// Top Credit/Cash toggle. Cash ⇒ invoice is paid in full on save; Credit ⇒
  /// nothing received (balance carried). Estimates ignore this.
  bool _isCash = true;

  /// The state the goods are being supplied to. Auto-filled from the selected
  /// party's billing state, but the user can override it. When this differs
  /// from the business state, all tax is treated as IGST (inter-state).
  String? _supplyState;

  int? _paymentModeId;
  int? _accountId;
  String _txnNumber = '';

  bool get _isPurchase =>
      widget.mode == TxnFormMode.purchase ||
      widget.mode == TxnFormMode.purchaseReturn ||
      widget.mode == TxnFormMode.purchaseOrder;
  bool get _isEstimate => widget.mode == TxnFormMode.estimate;
  bool get _isChallan => widget.mode == TxnFormMode.deliveryChallan;
  bool get _isCreditNote => widget.mode == TxnFormMode.saleReturn;
  bool get _isPurchaseReturn => widget.mode == TxnFormMode.purchaseReturn;
  bool get _isPurchaseOrder => widget.mode == TxnFormMode.purchaseOrder;
  bool get _isEdit => widget.existingId != null;
  // Estimates, delivery challans, purchase returns and purchase orders aren't
  // billed at creation, so they show no payment section (and therefore no
  // Cash/Credit toggle).
  bool get _showPayment =>
      !_isEstimate && !_isChallan && !_isPurchaseReturn && !_isPurchaseOrder;

  String get _typeLabel => switch (widget.mode) {
        TxnFormMode.sale => 'Sale Invoice',
        TxnFormMode.purchase => 'Purchase Bill',
        TxnFormMode.estimate => 'Estimate',
        TxnFormMode.saleReturn => 'Sale Return',
        TxnFormMode.saleOrder => 'Sale Order',
        TxnFormMode.deliveryChallan => 'Delivery Challan',
        TxnFormMode.paymentIn => 'Payment In',
        TxnFormMode.purchaseReturn => 'Purchase Return',
        TxnFormMode.purchaseOrder => 'Purchase Order',
        TxnFormMode.paymentOut => 'Payment Out',
      };

  /// Inter-state when the supply state differs from the business state.
  /// Uses the manually-set [_supplyState] (which is auto-filled from the
  /// selected party's billing state but can be overridden by the user).
  bool get _interState {
    final ss = _supplyState?.trim();
    final bs = _businessState?.trim();
    if (ss == null || ss.isEmpty || bs == null || bs.isEmpty) return false;
    return ss.toLowerCase() != bs.toLowerCase();
  }

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    _taxRates = await _taxRepo.getTaxRates();
    final biz = await DatabaseHelper.getBusiness();
    _businessState = biz?['state'] as String?;

    if (_isEdit) {
      await _loadExisting(widget.existingId!, copyNumber: true);
    } else {
      // New document: assign the next sequential number first…
      if (_isCreditNote) {
        _txnNumber = await _peekReturnNumber();
      } else if (_isChallan) {
        _txnNumber = await _peekChallanNumber();
      } else if (_isPurchaseReturn) {
        _txnNumber = await _peekPurchaseReturnNumber();
      } else if (_isPurchaseOrder) {
        _txnNumber = await _peekPurchaseOrderNumber();
      } else {
        _txnNumber = _isPurchase
            ? await _peekNumber('purchase')
            : await _peekNumber(_isEstimate ? 'estimate' : 'invoice');
      }
      // …then, if duplicating, copy the source's party / lines / notes onto it
      // (keeping the freshly-peeked number above).
      if (widget.duplicateFromId != null) {
        await _loadExisting(widget.duplicateFromId!, copyNumber: false);
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  /// Reads the next number without consuming the counter (consumed on save).
  Future<String> _peekNumber(String kind) async {
    final biz = await DatabaseHelper.getBusiness();
    if (kind == 'purchase') {
      final prefix = biz?['purchase_prefix'] as String? ?? 'PUR';
      final c = (biz?['purchase_counter'] as int?) ?? 1;
      return '$prefix-${c.toString().padLeft(4, '0')}';
    }
    final prefix = kind == 'estimate'
        ? 'EST'
        : (biz?['invoice_prefix'] as String? ?? 'INV');
    final c = (biz?['invoice_counter'] as int?) ?? 1;
    return '$prefix-${c.toString().padLeft(4, '0')}';
  }

  /// Next Credit Note number, derived from how many sale returns already exist.
  /// There is no dedicated counter column, so we count + 1 and label it "CN N".
  Future<String> _peekReturnNumber() async {
    final repo = ref.read(transactionRepositoryProvider);
    final count = await repo.countByType(TxnTypes.saleReturn);
    return 'CN ${count + 1}';
  }

  /// Next Purchase Return (Debit Note) number ("PR-1"). Derived from the count
  /// of existing purchase returns; does not consume the purchase counter.
  Future<String> _peekPurchaseReturnNumber() async {
    final repo = ref.read(transactionRepositoryProvider);
    final count = await repo.countByType(TxnTypes.purchaseReturn);
    return 'PR-${count + 1}';
  }

  /// Next Purchase Order number ("PO-01"). Derived from the count of existing
  /// purchase orders; does not consume the purchase counter.
  Future<String> _peekPurchaseOrderNumber() async {
    final repo = ref.read(transactionRepositoryProvider);
    final count = await repo.countByType(TxnTypes.purchaseOrder);
    return 'PO-${(count + 1).toString().padLeft(2, '0')}';
  }

  /// Next Delivery Challan number ("DC-0001"). Like estimates, challans have no
  /// dedicated counter column, so we derive it from the existing challan count
  /// and never consume the invoice counter.
  Future<String> _peekChallanNumber() async {
    final repo = ref.read(transactionRepositoryProvider);
    final count = await repo.countByType(TxnTypes.deliveryChallan);
    return 'DC-${(count + 1).toString().padLeft(4, '0')}';
  }

  /// Loads [sourceId] into the form. On edit ([copyNumber] true) this restores
  /// the document verbatim; when duplicating ([copyNumber] false) the previously
  /// peeked fresh number and today's date are kept so a new document is created.
  Future<void> _loadExisting(int sourceId, {required bool copyNumber}) async {
    final repo = ref.read(transactionRepositoryProvider);
    final txn = await repo.getById(sourceId);
    final items = await repo.getItems(sourceId);
    if (txn == null) return;

    if (copyNumber) {
      _txnNumber = txn.transactionNumber;
      _date = DateTime.tryParse(txn.transactionDate) ?? DateTime.now();
      _dueDate = txn.dueDate == null ? null : DateTime.tryParse(txn.dueDate!);
    }
    _notes.text = txn.notes ?? '';
    _reference.text = txn.referenceNumber ?? '';

    if (txn.partyId != null) {
      _party = await PartyRepository().getById(txn.partyId!);
      _billingName.text = _party?.name ?? '';
      _phone.text = _party?.phone ?? '';
      _supplyState = _party?.billingState;
    }
    _isCash = txn.paymentStatus == 'paid';

    for (final it in items) {
      final tiers =
          it.itemId == null ? <ItemUnit>[] : await _itemUnitRepo.getItemUnits(it.itemId!);
      _lines.add(LineDraft.fromItem(it, tiers: tiers, taxRates: _taxRates));
    }

    // Credit Note with no line items: surface its stored total / paid so the
    // editable amount fields are pre-filled, and the original invoice date.
    if (_isCreditNote && items.isEmpty) {
      _manualTotal.text =
          txn.totalAmount == 0 ? '' : Formatters.plain(txn.totalAmount);
      if (txn.paidAmount > 0) {
        _manualPaid.text = Formatters.plain(txn.paidAmount);
      }
    }
    if (_isCreditNote && txn.dueDate != null) {
      _invoiceDate = DateTime.tryParse(txn.dueDate!);
    }
  }

  @override
  void dispose() {
    _notes.dispose();
    _reference.dispose();
    _billingName.dispose();
    _phone.dispose();
    _manualTotal.dispose();
    _manualPaid.dispose();
    super.dispose();
  }

  TxnTotals get _totals {
    final lineItems = [
      for (var i = 0; i < _lines.length; i++) _lines[i].toItem(i)
    ];
    return TxnCalc.totals(lineItems, interState: _interState);
  }

  // ── Item handling ──────────────────────────────────────────────────────────

  Future<void> _addItem() async {
    final item = await showItemPicker(context);
    if (item == null) return;

    final draft = LineDraft(
      itemId: item.id,
      itemName: item.name,
      itemHsn: item.hsnCode,
      taxRateId: item.taxRateId,
      taxRate: item.taxRateValue ?? 0,
      taxInclusive: item.taxInclusive,
      unitPrice: _isPurchase ? item.purchasePrice : item.salePrice,
    );

    if (item.id != null) {
      final tiers = await _itemUnitRepo.getItemUnits(item.id!);
      draft.tiers = tiers;
      if (tiers.isNotEmpty) {
        final preferred = tiers.firstWhere(
          (t) => _isPurchase ? t.isDefaultPurchase : t.isDefaultSale,
          orElse: () => tiers.first,
        );
        draft.applyTier(preferred, isPurchase: _isPurchase);
      }
    }
    setState(() => _lines.add(draft));
  }

  // ── Save ─────────────────────────────────────────────────────────────────

  /// Persists the transaction and returns the saved row id, or `null` if
  /// validation failed or the save errored. On a successful create the id is the
  /// newly-inserted row; on edit it is [widget.existingId].
  Future<int?> _save({bool andNew = false, bool pop = true}) async {
    if (_isCreditNote) {
      return _saveCreditNote(andNew: andNew, pop: pop);
    }

    if (_lines.isEmpty) {
      _snack('Add at least one item');
      return null;
    }
    for (final l in _lines) {
      if (l.quantity <= 0) {
        _snack('Quantity must be greater than 0 for "${l.itemName}"');
        return null;
      }
    }

    setState(() => _saving = true);
    final totals = _totals;
    final repo = ref.read(transactionRepositoryProvider);

    // Cash ⇒ paid in full; Credit ⇒ nothing received. Estimates never pay.
    final received = _showPayment && _isCash ? totals.total : 0.0;

    final txnType = switch (widget.mode) {
      TxnFormMode.sale => TxnTypes.sale,
      TxnFormMode.purchase => TxnTypes.purchase,
      TxnFormMode.estimate => TxnTypes.estimate,
      TxnFormMode.saleReturn => TxnTypes.saleReturn,
      TxnFormMode.saleOrder => TxnTypes.saleOrder,
      TxnFormMode.deliveryChallan => TxnTypes.deliveryChallan,
      TxnFormMode.paymentIn => TxnTypes.paymentIn,
      TxnFormMode.purchaseReturn => TxnTypes.purchaseReturn,
      TxnFormMode.purchaseOrder => TxnTypes.purchaseOrder,
      TxnFormMode.paymentOut => TxnTypes.paymentOut,
    };

    final txn = Transaction(
      id: widget.existingId,
      partyId: _party?.id,
      accountId: received > 0 ? _accountId : null,
      transactionType: txnType,
      transactionNumber: _txnNumber,
      referenceNumber:
          _reference.text.trim().isEmpty ? null : _reference.text.trim(),
      transactionDate: _date.toIso8601String(),
      dueDate: _dueDate?.toIso8601String(),
      subtotal: totals.subtotal,
      discountAmount: totals.discountAmount,
      taxableAmount: totals.taxableAmount,
      taxAmount: totals.taxAmount,
      cgstAmount: totals.cgstAmount,
      sgstAmount: totals.sgstAmount,
      igstAmount: totals.igstAmount,
      roundOff: totals.roundOff,
      totalAmount: totals.total,
      status: _isEstimate ? 'draft' : 'active',
      notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    );

    final items = totals.lines;

    try {
      int savedId;
      if (_isEdit) {
        await repo.updateTransaction(txn, items);
        savedId = widget.existingId!;
      } else {
        Payment? payment;
        if (received > 0) {
          payment = Payment(
            accountId: _accountId,
            paymentModeId: _paymentModeId,
            amount: received.toDouble(),
            paymentDate: _date.toIso8601String(),
          );
        }
        // Only an actual Purchase Bill / Sale Invoice consumes a sequential
        // counter. Purchase returns/orders (PR-/PO-) and estimates/challans
        // derive their numbers from a count instead, so pass null.
        final String? counterField;
        if (widget.mode == TxnFormMode.purchase) {
          counterField = 'purchase_counter';
        } else if (_isEstimate ||
            _isChallan ||
            _isPurchaseReturn ||
            _isPurchaseOrder) {
          counterField = null;
        } else {
          counterField = 'invoice_counter';
        }
        savedId = await repo.create(
          txn,
          items,
          initialPayment: payment,
          counterField: counterField,
        );
      }
      ref.refreshTransactions();
      if (!mounted) return null;
      _snack('$_typeLabel saved');
      if (andNew && !_isEdit) {
        await _resetForNew();
      } else if (pop) {
        Navigator.pop(context, true);
      } else {
        setState(() => _saving = false);
      }
      return savedId;
    } catch (e) {
      if (!mounted) return null;
      setState(() => _saving = false);
      _snack('Could not save: $e');
      return null;
    }
  }

  /// Saves a Credit Note (sale return). Customer name is required; the amount
  /// may come from line items or be entered manually. The original invoice date
  /// is stored in [Transaction.dueDate] and the Inv No. in [referenceNumber].
  Future<int?> _saveCreditNote({bool andNew = false, bool pop = true}) async {
    final customerName = _billingName.text.trim();
    if (customerName.isEmpty) {
      _snack('Customer Name is required');
      return null;
    }

    final hasItems = _lines.isNotEmpty;
    if (hasItems) {
      for (final l in _lines) {
        if (l.quantity <= 0) {
          _snack('Quantity must be greater than 0 for "${l.itemName}"');
          return null;
        }
      }
    }

    final totals = _totals;
    final total = hasItems ? totals.total : (double.tryParse(_manualTotal.text) ?? 0);
    if (total <= 0) {
      _snack('Enter a total amount greater than 0');
      return null;
    }
    final paid = (double.tryParse(_manualPaid.text) ?? 0).clamp(0, total).toDouble();

    setState(() => _saving = true);
    final repo = ref.read(transactionRepositoryProvider);

    try {
      // Resolve the customer: reuse the picked party, else find an existing one
      // by name, else create a lightweight customer record.
      int? partyId = _party?.id;
      if (partyId == null) {
        final partyRepo = PartyRepository();
        final matches = await partyRepo.getParties(type: 'customer', search: customerName);
        final exact = matches.where(
            (p) => p.name.toLowerCase() == customerName.toLowerCase());
        if (exact.isNotEmpty) {
          partyId = exact.first.id;
        } else {
          partyId = await partyRepo.insert(Party(
            name: customerName,
            partyType: 'customer',
            phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          ));
        }
      }

      final txn = Transaction(
        id: widget.existingId,
        partyId: partyId,
        accountId: paid > 0 ? _accountId : null,
        transactionType: TxnTypes.saleReturn,
        transactionNumber: _txnNumber,
        referenceNumber:
            _reference.text.trim().isEmpty ? null : _reference.text.trim(),
        transactionDate: _date.toIso8601String(),
        dueDate: _invoiceDate?.toIso8601String(),
        subtotal: hasItems ? totals.subtotal : total,
        discountAmount: hasItems ? totals.discountAmount : 0,
        taxableAmount: hasItems ? totals.taxableAmount : total,
        taxAmount: hasItems ? totals.taxAmount : 0,
        cgstAmount: hasItems ? totals.cgstAmount : 0,
        sgstAmount: hasItems ? totals.sgstAmount : 0,
        igstAmount: hasItems ? totals.igstAmount : 0,
        roundOff: hasItems ? totals.roundOff : 0,
        totalAmount: total,
        status: 'active',
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      );

      final items = hasItems ? totals.lines : <TransactionItem>[];

      int savedId;
      if (_isEdit) {
        await repo.updateTransaction(txn, items);
        savedId = widget.existingId!;
      } else {
        Payment? payment;
        if (paid > 0) {
          payment = Payment(
            accountId: _accountId,
            paymentModeId: _paymentModeId,
            amount: paid,
            paymentDate: _date.toIso8601String(),
          );
        }
        // No dedicated counter column for credit notes; numbering is derived.
        savedId = await repo.create(txn, items, initialPayment: payment);
      }

      ref.refreshTransactions();
      if (!mounted) return null;
      _snack('Credit Note saved');
      if (andNew && !_isEdit) {
        await _resetForNew();
      } else if (pop) {
        Navigator.pop(context, true);
      } else {
        setState(() => _saving = false);
      }
      return savedId;
    } catch (e) {
      if (!mounted) return null;
      setState(() => _saving = false);
      _snack('Could not save: $e');
      return null;
    }
  }

  // ── Share / Print (top-bar actions) ─────────────────────────────────────────

  /// Builds the document PDF for the freshly-saved [transactionId] by re-reading
  /// the persisted row + items, so the PDF always reflects exactly what was
  /// stored (numbers, paid amount, party).
  Future<Uint8List> _buildPdf(int transactionId) async {
    final repo = ref.read(transactionRepositoryProvider);
    final txn = await repo.getById(transactionId);
    final items = await repo.getItems(transactionId);
    if (txn == null) {
      throw StateError('Saved transaction $transactionId could not be loaded');
    }
    return InvoicePdfService.build(transaction: txn, items: items);
  }

  /// Saves the document (without leaving the screen) and then opens the
  /// "Share transaction" chooser (Image / PDF). A no-op if the save fails
  /// validation.
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

  /// Saves the document (without leaving the screen) and then opens the print
  /// dialog with its PDF.
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

  /// Clears the form after a "Save & New" so the next entry starts blank, and
  /// fetches the freshly-incremented next number.
  Future<void> _resetForNew() async {
    final next = _isCreditNote
        ? await _peekReturnNumber()
        : _isChallan
            ? await _peekChallanNumber()
            : _isPurchase
                ? await _peekNumber('purchase')
                : await _peekNumber(_isEstimate ? 'estimate' : 'invoice');
    if (!mounted) return;
    setState(() {
      _lines.clear();
      _party = null;
      _billingName.clear();
      _phone.clear();
      _notes.clear();
      _reference.clear();
      _manualTotal.clear();
      _manualPaid.clear();
      _date = DateTime.now();
      _dueDate = null;
      _invoiceDate = null;
      _saving = false;
      _txnNumber = next;
    });
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: Text(_typeLabel)),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final totals = _totals;
    final totalQty = _lines.fold<double>(0, (s, l) => s + l.quantity);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: const Border(bottom: BorderSide(color: AppColors.divider)),
        title: Text(_headerTitle,
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700)),
        actions: [
          // Credit Notes have no Credit/Cash toggle (see reference UI).
          if (_showPayment && !_isCreditNote) _creditCashToggle(),
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Share',
            onPressed: _saving ? null : _saveAndShare,
          ),
          _overflowMenu(),
          const SizedBox(width: 4),
        ],
      ),
      body: _isCreditNote
          ? _creditNoteBody()
          : ListView(
        padding: EdgeInsets.zero,
        children: [
          _invoiceHeaderRow(),
          const Divider(height: 1, thickness: 6, color: AppColors.backgroundLight),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _billingFields(),
          ),
          const SizedBox(height: 12),
          _billedItemsSection(totals, totalQty),
          const SizedBox(height: 16),
          _totalAmountBar(totals.total),
          if (_showPayment) _paymentSection(),
          _extraFields(),
          const SizedBox(height: 24),
        ],
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  String get _headerTitle => switch (widget.mode) {
        TxnFormMode.sale => 'Sale',
        TxnFormMode.purchase => 'Purchase',
        TxnFormMode.estimate => 'Estimate',
        TxnFormMode.saleReturn => 'Sale Return',
        TxnFormMode.saleOrder => 'Sale Order',
        TxnFormMode.deliveryChallan => 'Delivery Challan',
        TxnFormMode.paymentIn => 'Payment In',
        TxnFormMode.purchaseReturn => 'Purchase Return',
        TxnFormMode.purchaseOrder => 'Purchase Order',
        TxnFormMode.paymentOut => 'Payment Out',
      };

  // ── Credit Note (sale return) layout ────────────────────────────────────────

  /// Effective total for a Credit Note: line-item total when items exist,
  /// otherwise the manually-entered amount.
  double get _creditNoteTotal =>
      _lines.isNotEmpty ? _totals.total : (double.tryParse(_manualTotal.text) ?? 0);

  double get _creditNotePaid => double.tryParse(_manualPaid.text) ?? 0;

  Widget _creditNoteBody() {
    final total = _creditNoteTotal;
    final paid = _creditNotePaid;
    final balance = total - paid;

    return ListView(
      padding: EdgeInsets.zero,
      children: [
        _returnHeaderRow(),
        const Divider(height: 1, thickness: 6, color: AppColors.backgroundLight),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(
            children: [
              TextField(
                controller: _billingName,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Customer Name *',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  hintText: 'Phone Number',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _invoiceDateField()),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _reference,
                      decoration: const InputDecoration(
                        hintText: 'Inv No.',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.add_circle, color: AppColors.partial),
                label: const Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: 'Add Items ',
                        style: TextStyle(
                            color: AppColors.partial,
                            fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: '(Optional)',
                        style: TextStyle(color: AppColors.textSecondary)),
                  ]),
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                  side: const BorderSide(color: AppColors.border),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: _addItem,
              ),
            ],
          ),
        ),
        // Show added line items (if any) inline.
        if (_lines.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                const SizedBox(height: 4),
                for (var i = 0; i < _lines.length; i++)
                  ItemLineWidget(
                    key: ObjectKey(_lines[i]),
                    index: i + 1,
                    draft: _lines[i],
                    taxRates: _taxRates,
                    isPurchase: false,
                    interState: _interState,
                    onChanged: () => setState(() {}),
                    onRemove: () => setState(() => _lines.removeAt(i)),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        _creditNoteSummary(total, paid, balance),
        _paymentSection(),
        _extraFields(),
        const SizedBox(height: 24),
      ],
    );
  }

  /// Return No. + Date header row (Credit Note variant of [_invoiceHeaderRow]).
  Widget _returnHeaderRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _labelledValue('Return No.', _txnNumber, chevron: true),
          ),
          Container(
            width: 1,
            height: 36,
            color: AppColors.divider,
            margin: const EdgeInsets.symmetric(horizontal: 12),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: _labelledValue(
                'Date',
                Formatters.date(_date.toIso8601String()),
                chevron: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Original-invoice date picker, styled as an outlined field with a calendar
  /// icon to match the reference layout.
  Widget _invoiceDateField() {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _invoiceDate ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) setState(() => _invoiceDate = picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(border: OutlineInputBorder()),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _invoiceDate == null
                  ? 'Invoice Date'
                  : Formatters.date(_invoiceDate!.toIso8601String()),
              style: TextStyle(
                color: _invoiceDate == null
                    ? AppColors.textHint
                    : AppColors.textPrimary,
              ),
            ),
            const Icon(Icons.calendar_today,
                size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  /// Total Amount (editable when no line items) / Paid (editable) / Balance Due.
  Widget _creditNoteSummary(double total, double paid, double balance) {
    return Container(
      color: AppColors.backgroundLight,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        children: [
          _summaryRow(
            'Total Amount',
            _lines.isEmpty
                ? _editableAmountField(_manualTotal)
                : Text(Formatters.currency(total),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          _summaryRow('Paid', _editableAmountField(_manualPaid)),
          const SizedBox(height: 4),
          _summaryRow(
            'Balance Due',
            Text(Formatters.currency(balance),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary)),
            labelColor: AppColors.primary,
          ),
        ],
      ),
    );
  }

  Widget _summaryRow(String label, Widget trailing, {Color? labelColor}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: labelColor ?? AppColors.textPrimary)),
        Flexible(child: Align(alignment: Alignment.centerRight, child: trailing)),
      ],
    );
  }

  /// Inline editable ₹ amount with a dashed-style underline, right-aligned.
  Widget _editableAmountField(TextEditingController controller) {
    return SizedBox(
      width: 160,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('₹ ',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => setState(() {}),
              textAlign: TextAlign.right,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              decoration: const InputDecoration(
                isDense: true,
                hintText: '0',
                contentPadding: EdgeInsets.symmetric(vertical: 4),
                enabledBorder: UnderlineInputBorder(
                    borderSide:
                        BorderSide(color: AppColors.partial, width: 1)),
                focusedBorder: UnderlineInputBorder(
                    borderSide:
                        BorderSide(color: AppColors.partial, width: 1.5)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Header: overflow (three-dots) menu ──────────────────────────────────────

  /// Three-dots menu shown on every sale-document creation screen. Items save
  /// the document first (staying on-screen), then act on its PDF. The set is
  /// intentionally small for now and easy to extend later.
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
            // Settings screen wiring to come.
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

  // ── Header: Credit / Cash toggle ────────────────────────────────────────────

  Widget _creditCashToggle() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.backgroundLight,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _togglePill('Credit', !_isCash, () => setState(() => _isCash = false)),
          _togglePill('Cash', _isCash, () => setState(() => _isCash = true)),
        ],
      ),
    );
  }

  Widget _togglePill(String label, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: active ? AppColors.accent : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Text(label,
            style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : AppColors.textSecondary)),
      ),
    );
  }

  // ── Invoice no. + date ──────────────────────────────────────────────────────

  Widget _invoiceHeaderRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: [
          Expanded(
            child: _labelledValue(
              _isEstimate
                  ? 'Estimate No.'
                  : _isChallan
                      ? 'Challan No.'
                      : 'Invoice No.',
              _txnNumber,
            ),
          ),
          Container(
            width: 1,
            height: 36,
            color: AppColors.divider,
            margin: const EdgeInsets.symmetric(horizontal: 12),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: _labelledValue(
                'Date',
                Formatters.date(_date.toIso8601String()),
                chevron: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _labelledValue(String label, String value, {bool chevron = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style:
                const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(value,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600)),
            if (chevron)
              const Icon(Icons.keyboard_arrow_down,
                  size: 20, color: AppColors.textSecondary),
          ],
        ),
      ],
    );
  }

  // ── Billing name + phone ────────────────────────────────────────────────────

  Widget _billingFields() {
    return Column(
      children: [
        InkWell(
          onTap: _pickParty,
          borderRadius: BorderRadius.circular(8),
          child: IgnorePointer(
            child: TextField(
              controller: _billingName,
              decoration: InputDecoration(
                labelText:
                    _isPurchase ? 'Supplier Name' : 'Billing Name (Optional)',
                border: const OutlineInputBorder(),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            hintText: 'Phone Number',
            border: OutlineInputBorder(),
          ),
        ),
        if (_interState)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Inter-state (IGST)',
                  style: TextStyle(fontSize: 12, color: AppColors.partial)),
            ),
          ),
      ],
    );
  }

  // ── Billed items ────────────────────────────────────────────────────────────

  Widget _billedItemsSection(TxnTotals totals, double totalQty) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Blue "Billed Items" header bar.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: AppColors.partial.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Row(
              children: [
                Icon(Icons.check_circle, size: 18, color: AppColors.partial),
                SizedBox(width: 8),
                Text('Billed Items',
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: AppColors.partial)),
              ],
            ),
          ),
          const SizedBox(height: 12),
          if (_lines.isEmpty)
            Container(
              padding: const EdgeInsets.all(24),
              alignment: Alignment.center,
              child: const Text('No items added',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
          for (var i = 0; i < _lines.length; i++)
            ItemLineWidget(
              key: ObjectKey(_lines[i]),
              index: i + 1,
              draft: _lines[i],
              taxRates: _taxRates,
              isPurchase: _isPurchase,
              interState: _interState,
              onChanged: () => setState(() {}),
              onRemove: () => setState(() => _lines.removeAt(i)),
            ),
          if (_lines.isNotEmpty)
            TotalsStrip(totals: totals, totalQty: totalQty),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            icon: const Icon(Icons.add_circle, color: AppColors.partial),
            label: const Text('Add Items',
                style: TextStyle(
                    color: AppColors.partial, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              side: const BorderSide(color: AppColors.border),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _addItem,
          ),
        ],
      ),
    );
  }

  // ── Total amount bar ────────────────────────────────────────────────────────

  Widget _totalAmountBar(double total) {
    return Container(
      color: AppColors.backgroundLight,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Text('Total Amount',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          Text(
            Formatters.currency(total),
            style: const TextStyle(
                fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Future<void> _pickParty() async {
    final p = await showPartyPicker(context,
        type: _isPurchase ? 'supplier' : 'customer');
    if (p != null) {
      setState(() {
        _party = p;
        _billingName.text = p.name;
        if ((p.phone ?? '').isNotEmpty) _phone.text = p.phone!;
        // Auto-fill supply state from party; user can still override below.
        if ((p.billingState ?? '').isNotEmpty) {
          _supplyState = p.billingState;
        }
      });
    }
  }

  // ── Payment type + state of supply ──────────────────────────────────────────

  Widget _paymentSection() {
    final modes = ref.watch(paymentModesProvider);
    final accounts = ref.watch(accountsProvider);
    accounts.whenData((list) {
      _accountId ??= list.where((a) => a.isDefault).firstOrNull?.id ??
          list.firstOrNull?.id;
    });

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text('Payment Type',
                    style: TextStyle(fontSize: 15)),
              ),
              modes.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (list) {
                  _paymentModeId ??=
                      list.where((m) => m.type == 'cash').firstOrNull?.id;
                  return DropdownButton<int>(
                    value: _paymentModeId,
                    underline: const SizedBox.shrink(),
                    icon: const Icon(Icons.keyboard_arrow_down,
                        color: AppColors.textSecondary),
                    items: list
                        .map((m) => DropdownMenuItem(
                            value: m.id,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.currency_rupee,
                                    size: 16, color: AppColors.accent),
                                const SizedBox(width: 6),
                                Text(m.name),
                              ],
                            )))
                        .toList(),
                    onChanged: (v) => setState(() => _paymentModeId = v),
                  );
                },
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.add, size: 18, color: AppColors.partial),
              label: const Text('Add Payment Type',
                  style: TextStyle(color: AppColors.partial)),
              onPressed: () {},
            ),
          ),
          const Divider(height: 1),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Deposit to',
                  style: TextStyle(fontSize: 15)),
              accounts.when(
                loading: () => const SizedBox.shrink(),
                error: (_, _) => const SizedBox.shrink(),
                data: (list) => DropdownButton<int>(
                  value: _accountId,
                  underline: const SizedBox.shrink(),
                  icon: const Icon(Icons.keyboard_arrow_down,
                      color: AppColors.textSecondary),
                  items: list
                      .map((a) =>
                          DropdownMenuItem(value: a.id, child: Text(a.name)))
                      .toList(),
                  onChanged: (v) => setState(() => _accountId = v),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(height: 1),
          const SizedBox(height: 12),
          // ── State of Supply ──────────────────────────────────────────────
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('State of Supply', style: TextStyle(fontSize: 15)),
              DropdownButton<String>(
                value: AppLists.indianStates.contains(_supplyState)
                    ? _supplyState
                    : null,
                hint: const Text('Select State',
                    style: TextStyle(color: AppColors.textSecondary)),
                underline: const SizedBox.shrink(),
                icon: const Icon(Icons.keyboard_arrow_down,
                    color: AppColors.textSecondary),
                items: AppLists.indianStates
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => setState(() => _supplyState = v),
              ),
            ],
          ),
          if (_interState)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      size: 14, color: AppColors.partial),
                  const SizedBox(width: 6),
                  Text(
                    'Inter-state supply — IGST applies',
                    style: TextStyle(
                        fontSize: 12,
                        color: AppColors.partial,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 12),
          const Divider(height: 1, thickness: 6, color: AppColors.backgroundLight),
        ],
      ),
    );
  }

  // ── Bottom action bar ───────────────────────────────────────────────────────

  Widget _bottomBar() {
    return SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.divider)),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  foregroundColor: AppColors.textPrimary,
                ),
                onPressed: _saving ? null : () => _save(andNew: true),
                child: const Text('Save & New',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
            Expanded(
              child: Container(
                color: AppColors.partial,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    foregroundColor: Colors.white,
                  ),
                  onPressed: _saving ? null : () => _save(),
                  child: _saving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save',
                          style: TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 16)),
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: _saving ? null : () => _save(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _extraFields() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isEstimate)
            _dateTile('Due Date', _dueDate,
                (d) => setState(() => _dueDate = d),
                clearable: true),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _notes,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    hintText: 'Add Note',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              _attachBox(),
            ],
          ),
          // Credit Notes capture the original invoice number via the "Inv No."
          // field above, so the shared Reference No. field is omitted here to
          // avoid binding _reference to two TextFields at once.
          if (!_isCreditNote) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _reference,
              decoration: InputDecoration(
                labelText:
                    _isPurchase ? 'Supplier Invoice No.' : 'Reference No.',
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Image-attach placeholder matching the screenshots' "+ image" box.
  Widget _attachBox() {
    return Container(
      width: 78,
      height: 78,
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Icon(Icons.image_outlined, size: 36, color: AppColors.textHint),
          Positioned(
            top: 6,
            left: 6,
            child: Container(
              decoration: const BoxDecoration(
                  color: AppColors.partial, shape: BoxShape.circle),
              child: const Icon(Icons.add, size: 16, color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _dateTile(String label, DateTime? value, ValueChanged<DateTime> onPick,
      {bool clearable = false}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 13)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value == null ? 'Not set' : Formatters.date(value.toIso8601String()),
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          if (clearable && value != null)
            IconButton(
              icon: const Icon(Icons.clear, size: 18),
              onPressed: () => setState(() => _dueDate = null),
            ),
          const Icon(Icons.calendar_today, size: 16),
        ],
      ),
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: value ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) onPick(picked);
      },
    );
  }
}
