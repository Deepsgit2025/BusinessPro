import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_lists.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/responsive.dart';
import '../../../shared/widgets/wide_shell_scaffold.dart';
import '../../../services/ocr/bill_parser.dart';
import '../../../services/ocr/bill_scanner_service.dart';
import '../../items/models/item.dart';
import '../../items/models/item_unit.dart';
import '../../items/models/tax_rate.dart';
import '../../items/repositories/item_repository.dart';
import '../../items/repositories/item_unit_repository.dart';
import '../../items/repositories/tax_rate_repository.dart';
import '../../parties/models/party.dart';
import '../../parties/repositories/party_repository.dart';
import '../models/payment.dart';
import '../models/transaction.dart';
import '../models/transaction_item.dart';
import '../providers/transaction_providers.dart';
import '../services/invoice_format_registry.dart';
import '../services/transaction_share_service.dart';
import '../utils/txn_calc.dart';
import 'bill_preview_screen.dart';
import '../widgets/billing_name_field.dart';
import '../widgets/edit_number_dialog.dart';
import '../widgets/item_line_widget.dart';
import '../widgets/item_row_widget.dart';
import '../widgets/item_picker.dart';
import '../widgets/line_draft.dart';
import '../widgets/print_copies_sheet.dart';
import '../widgets/totals_section.dart';
import 'scan_result_screen.dart';

/// True on platforms where Scan Bill (camera + ML Kit OCR) is unavailable.
/// ML Kit ships only Android/iOS implementations; this app targets Android +
/// Windows desktop, so the feature is hidden everywhere except Android.
final bool kIsScanUnsupported = !Platform.isAndroid;

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

  /// True while a scanned bill is being OCR'd / parsed, to gate the overlay.
  bool _scanning = false;

  /// Set just before a successful-save pop so the [PopScope] guard lets that
  /// programmatic pop through without prompting to discard.
  bool _saved = false;

  // Form state.
  Party? _party;
  final List<LineDraft> _lines = [];
  DateTime _date = DateTime.now();
  DateTime? _dueDate;
  final _notes = TextEditingController();
  final _reference = TextEditingController();
  final _billingName = TextEditingController();
  final _phone = TextEditingController();
  // One-off billing GSTIN + address (wide layout). Prefilled from a picked
  // party; persisted on the document when no party is linked.
  final _gstin = TextEditingController();
  final _address = TextEditingController();

  // Inline document-number editing (wide layout): the field edits [_txnNumber]
  // directly. Uniqueness is validated when the field is committed (focus lost /
  // submitted); a clash reverts to the last good value.
  final _numberCtrl = TextEditingController();
  final _numberFocus = FocusNode();
  String _lastGoodNumber = '';

  // ── Invoice Format 1: transport & delivery + shipping (sale invoices only) ──
  final _ewayBill = TextEditingController();
  final _transportName = TextEditingController();
  final _vehicleNumber = TextEditingController();
  final _deliveryLocation = TextEditingController();
  DateTime? _deliveryDate;
  bool _transportExpanded = false;

  final _shipAddress = TextEditingController();
  final _shipCity = TextEditingController();
  final _shipPincode = TextEditingController();
  String? _shipState;
  bool _shippingDiff = false;

  // Credit Note (sale return) only: a manually-entered total + amount paid,
  // used when the note is recorded as a flat amount without line items.
  final _manualTotal = TextEditingController();
  final _manualPaid = TextEditingController();

  /// Credit mode only: the amount actually received against this invoice.
  /// Empty ⇒ ₹0 received (full balance carried). Balance Due is computed live
  /// as Total − Received. Ignored in Cash mode (invoice is paid in full).
  final _received = TextEditingController();

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

  /// The auto-generated number first shown for a NEW document, kept so we can
  /// tell whether the user manually overrode it. When overridden, saving a sale/
  /// purchase does NOT consume the running counter (so the sequence isn't left
  /// with a gap for a number that was never used). Null while editing.
  String? _autoNumber;
  bool get _numberOverridden =>
      _autoNumber != null && _txnNumber != _autoNumber;

  bool get _isPurchase =>
      widget.mode == TxnFormMode.purchase ||
      widget.mode == TxnFormMode.purchaseReturn ||
      widget.mode == TxnFormMode.purchaseOrder;
  bool get _isSale => widget.mode == TxnFormMode.sale;
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
    // Commit the inline number edit when the field loses focus.
    _numberFocus.addListener(() {
      if (!_numberFocus.hasFocus) _commitInlineNumber();
    });
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
      // Remember the auto-generated number so an override can be detected on
      // save (see _numberOverridden / counterType below).
      _autoNumber = _txnNumber;
      // …then, if duplicating, copy the source's party / lines / notes onto it
      // (keeping the freshly-peeked number above).
      if (widget.duplicateFromId != null) {
        await _loadExisting(widget.duplicateFromId!, copyNumber: false);
      }
    }
    // Seed the inline number field once the number is resolved.
    _numberCtrl.text = _txnNumber;
    _lastGoodNumber = _txnNumber;
    if (mounted) setState(() => _loading = false);
  }

  /// Validates and commits the inline-edited document number. Empty input or an
  /// unchanged value reverts to the last good number; a value already used by
  /// another document is rejected (revert + snack). Mirrors the validation the
  /// old dialog did, just without the popup.
  void _commitInlineNumber() async {
    final entered = _numberCtrl.text.trim();
    if (entered == _lastGoodNumber) return;
    if (entered.isEmpty) {
      _numberCtrl.text = _lastGoodNumber;
      return;
    }
    final repo = ref.read(transactionRepositoryProvider);
    final clash = await repo.numberExists(entered, excludeId: widget.existingId);
    if (!mounted) return;
    if (clash) {
      _numberCtrl.text = _lastGoodNumber;
      _snack('That number is already used');
      return;
    }
    setState(() {
      _txnNumber = entered;
      _lastGoodNumber = entered;
    });
  }

  /// Reads the next number without consuming the counter (consumed on save).
  /// Windows prepends `W-` (see [DatabaseHelper.deviceDocPrefix]) so the two
  /// devices never generate colliding ids.
  Future<String> _peekNumber(String kind) async {
    // All auto-numbered types now share one reserved per-prefix counter scheme
    // (counter_<type>_<PREFIX>), previewed without consuming. The previewed
    // value is exactly what the atomic mint at save will produce. Sale/purchase
    // honour their configurable prefix; estimate keeps its EST sequence (seeded
    // once from the existing estimate count so existing data isn't renumbered).
    if (kind == 'purchase') {
      return DatabaseHelper.peekDocNumberForType(TxnTypes.purchase);
    }
    if (kind == 'estimate') {
      return DatabaseHelper.peekDocNumberForType(TxnTypes.estimate);
    }
    return DatabaseHelper.peekDocNumberForType(TxnTypes.sale);
  }

  /// Next Credit Note number ("CN N"), previewed from the reserved sale_return
  /// counter (seeded once from the existing count). The mint at save reserves it
  /// atomically, so two credit notes can never share a number.
  Future<String> _peekReturnNumber() =>
      DatabaseHelper.peekDocNumberForType(TxnTypes.saleReturn);

  /// Next Purchase Return (Debit Note) number ("PR-N"), from the reserved
  /// purchase_return counter.
  Future<String> _peekPurchaseReturnNumber() =>
      DatabaseHelper.peekDocNumberForType(TxnTypes.purchaseReturn);

  /// Next Purchase Order number ("PO-01"), from the reserved purchase_order
  /// counter.
  Future<String> _peekPurchaseOrderNumber() =>
      DatabaseHelper.peekDocNumberForType(TxnTypes.purchaseOrder);

  /// Next Delivery Challan number ("DC-0001"), from the reserved
  /// delivery_challan counter.
  Future<String> _peekChallanNumber() =>
      DatabaseHelper.peekDocNumberForType(TxnTypes.deliveryChallan);

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

    // Invoice Format 1 transport / shipping fields (sale invoices).
    _ewayBill.text = txn.ewayBillNumber ?? '';
    _transportName.text = txn.transportName ?? '';
    _vehicleNumber.text = txn.vehicleNumber ?? '';
    _deliveryLocation.text = txn.deliveryLocation ?? '';
    _deliveryDate =
        txn.deliveryDate == null ? null : DateTime.tryParse(txn.deliveryDate!);
    _shippingDiff = txn.isShippingDiff;
    _shipAddress.text = txn.shippingAddress ?? '';
    _shipCity.text = txn.shippingCity ?? '';
    _shipState = txn.shippingState;
    _shipPincode.text = txn.shippingPincode ?? '';
    // Expand the transport panel if any of its fields carry data.
    _transportExpanded = (txn.ewayBillNumber ?? '').isNotEmpty ||
        (txn.transportName ?? '').isNotEmpty ||
        (txn.vehicleNumber ?? '').isNotEmpty ||
        (txn.deliveryLocation ?? '').isNotEmpty ||
        txn.deliveryDate != null;

    if (txn.partyId != null) {
      _party = await PartyRepository().getById(txn.partyId!);
      _billingName.text = _party?.name ?? '';
      _phone.text = _party?.phone ?? '';
      _gstin.text = _party?.gstin ?? '';
      _address.text = _party?.billingAddress ?? '';
      _supplyState = _party?.billingState;
    } else if ((txn.billingName ?? '').isNotEmpty ||
        (txn.billingGstin ?? '').isNotEmpty ||
        (txn.billingAddress ?? '').isNotEmpty) {
      // One-off (free-text) party: no party record, restore the typed details.
      _billingName.text = txn.billingName ?? '';
      _gstin.text = txn.billingGstin ?? '';
      _address.text = txn.billingAddress ?? '';
    }
    // The State of Supply that was actually billed is stored in placeOfSupply;
    // it wins over the party's current billing state so re-opening an old doc
    // shows (and re-applies the tax of) the state it was saved with.
    final savedSupply = (txn.placeOfSupply ?? '').trim();
    if (savedSupply.isNotEmpty && AppLists.indianStates.contains(savedSupply)) {
      _supplyState = savedSupply;
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
    _gstin.dispose();
    _address.dispose();
    _numberCtrl.dispose();
    _numberFocus.dispose();
    _manualTotal.dispose();
    _manualPaid.dispose();
    _received.dispose();
    _ewayBill.dispose();
    _transportName.dispose();
    _vehicleNumber.dispose();
    _deliveryLocation.dispose();
    _shipAddress.dispose();
    _shipCity.dispose();
    _shipPincode.dispose();
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
    final draft = await _draftFromItem(item);
    setState(() => _lines.add(draft));
  }

  /// Builds a [LineDraft] from a master [Item]: copies name/hsn/tax/price and,
  /// for a real (saved) item, loads its unit tiers and applies the preferred
  /// sale/purchase tier. A free-text item (id == null) yields a plain draft.
  /// Shared by [_addItem] (picker) and the wide item-row autocomplete.
  Future<LineDraft> _draftFromItem(Item item) async {
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
    return draft;
  }

  /// Appends a blank free-text line (wide item table "Add Items"): the user
  /// types the item name inline, choosing a saved item from the dropdown or
  /// keeping free text.
  void _addBlankLine() {
    setState(() => _lines.add(LineDraft(itemName: '')));
  }

  // ── Scan Bill (OCR purchase entry) ──────────────────────────────────────────

  /// Whether the Scan Bill entry point should be shown: only for purchase bills,
  /// and only on Android (ML Kit / camera are unavailable on desktop).
  bool get _canScanBill =>
      widget.mode == TxnFormMode.purchase && !kIsScanUnsupported;

  /// Opens the source chooser, runs OCR + parsing on the picked image, shows the
  /// review screen, and applies the confirmed data to the form. The photo is
  /// never persisted — it lives only in memory for the OCR pass.
  Future<void> _scanBill() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (_) => _scanSourceSheet(),
    );
    if (source == null || !mounted) return;

    final picker = ImagePicker();
    final XFile? image;
    try {
      image = await picker.pickImage(source: source, maxWidth: 2000);
    } catch (e) {
      if (mounted) _snack('Could not open ${source == ImageSource.camera ? 'camera' : 'gallery'}');
      return;
    }
    if (image == null || !mounted) return;

    setState(() => _scanning = true);
    final scanner = BillScannerService();
    BillParseResult? parsed;
    try {
      final text = await scanner.extractText(image);
      if (text.trim().isEmpty) {
        if (mounted) {
          setState(() => _scanning = false);
          _snack('Could not read bill clearly, please try again');
        }
        return;
      }
      parsed = const BillParser().parse(text);
    } catch (e) {
      if (mounted) {
        setState(() => _scanning = false);
        _snack('Could not read bill clearly, please try again');
      }
      return;
    } finally {
      scanner.dispose();
    }

    if (!mounted) return;
    setState(() => _scanning = false);

    final confirmed = await Navigator.push<BillParseResult>(
      context,
      MaterialPageRoute(builder: (_) => ScanResultScreen(result: parsed!)),
    );
    if (confirmed != null && mounted) {
      await _applyScannedData(confirmed);
    }
  }

  Widget _scanSourceSheet() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Scan Purchase Bill',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _scanSourceButton(
                    icon: Icons.photo_camera_outlined,
                    label: 'Take Photo',
                    source: ImageSource.camera,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _scanSourceButton(
                    icon: Icons.photo_library_outlined,
                    label: 'Choose from Gallery',
                    source: ImageSource.gallery,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Works best with clear, printed bills. Hindi and English supported.\n'
              'Tip: good lighting and a flat surface give the best results.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scanSourceButton({
    required IconData icon,
    required String label,
    required ImageSource source,
  }) {
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 18),
        side: const BorderSide(color: AppColors.border),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      onPressed: () => Navigator.pop(context, source),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 28, color: AppColors.partial),
          const SizedBox(height: 8),
          Text(label,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  /// Applies a confirmed scan to the form: matches/pre-fills the supplier,
  /// reference number and date, then matches each line item to the items master
  /// (falling back to a free-text line). Amounts are informational only — the
  /// form recomputes totals from the line items.
  Future<void> _applyScannedData(BillParseResult r) async {
    final partyRepo = PartyRepository();
    final itemRepo = ItemRepository();

    // 1. Supplier — match by GSTIN first (exact), then by name, else pre-fill.
    Party? matched;
    if (r.supplierGstin != null) {
      final suppliers = await partyRepo.getParties(type: 'supplier');
      final g = r.supplierGstin!.toUpperCase();
      matched = suppliers
          .where((s) => (s.gstin ?? '').toUpperCase() == g)
          .firstOrNull;
    }
    if (matched == null && r.supplierName != null) {
      final byName = await partyRepo.getParties(
          type: 'supplier', search: r.supplierName);
      final lower = r.supplierName!.toLowerCase();
      matched = byName.where((s) => s.name.toLowerCase() == lower).firstOrNull ??
          byName.firstOrNull;
    }

    // 2. Resolve line items against the items master.
    final drafts = <LineDraft>[];
    for (final parsed in r.lineItems) {
      final candidates = await itemRepo.getItems(search: parsed.itemName);
      final lower = parsed.itemName.toLowerCase();
      final Item? item = candidates
              .where((c) => c.name.toLowerCase() == lower)
              .firstOrNull ??
          candidates.firstOrNull;

      if (item != null) {
        final draft = LineDraft(
          itemId: item.id,
          itemName: item.name,
          itemHsn: item.hsnCode,
          taxRateId: item.taxRateId,
          taxRate: item.taxRateValue ?? 0,
          taxInclusive: item.taxInclusive,
          quantity: parsed.quantity ?? 1,
          unitPrice: parsed.unitPrice ?? item.purchasePrice,
        );
        if (item.id != null) {
          final tiers = await _itemUnitRepo.getItemUnits(item.id!);
          draft.tiers = tiers;
          final preferred = tiers
              .where((t) => t.isDefaultPurchase)
              .firstOrNull ??
              tiers.firstOrNull;
          if (preferred != null) {
            draft.applyTier(preferred, isPurchase: true);
            // Keep the scanned price/qty over the tier defaults.
            draft.quantity = parsed.quantity ?? draft.quantity;
            if (parsed.unitPrice != null) draft.unitPrice = parsed.unitPrice!;
          }
        }
        drafts.add(draft);
      } else {
        // Free-text line: no master item, just the scanned name / qty / price.
        drafts.add(LineDraft(
          itemName: parsed.itemName,
          quantity: parsed.quantity ?? 1,
          unitPrice: parsed.unitPrice ?? 0,
        ));
      }
    }

    if (!mounted) return;
    setState(() {
      if (matched != null) {
        _party = matched;
        _billingName.text = matched.name;
        if ((matched.phone ?? '').isNotEmpty) _phone.text = matched.phone!;
        if ((matched.billingState ?? '').isNotEmpty) {
          _supplyState = matched.billingState;
        }
      } else if (r.supplierName != null) {
        _billingName.text = r.supplierName!;
      }
      if (r.billNumber != null) _reference.text = r.billNumber!;
      if (r.billDate != null) _date = r.billDate!;
      _lines.addAll(drafts);
    });

    final foundItems = drafts.length;
    _snack(foundItems > 0
        ? 'Applied scanned bill — $foundItems item(s) added, please review'
        : 'Applied scanned bill — please add items and review');
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

    // Cash ⇒ paid in full. Credit ⇒ whatever was typed in the Received field
    // (empty ⇒ ₹0, balance carried), clamped to the total. The repository's
    // payment trigger then derives paid_amount / balance_amount / status.
    // Estimates and other non-billed docs never pay.
    final double received;
    if (!_showPayment) {
      received = 0.0;
    } else if (_isCash) {
      received = totals.total;
    } else {
      received =
          (double.tryParse(_received.text.trim()) ?? 0).clamp(0, totals.total).toDouble();
    }

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

    final typedName = _billingName.text.trim();

    // Credit sale/purchase to a typed-in name (no party picked): promote that
    // name to a real party and link the document to it, so the person shows up
    // in Parties with the balance they owe (or are owed). We only do this when
    // the document actually carries a balance (credit) — a fully-paid cash sale
    // to a walk-in stays free-text and doesn't clutter the party list. Estimates
    // / challans / orders aren't billed (_showPayment == false) so never qualify.
    // Edits keep their existing linkage untouched.
    int? resolvedPartyId = _party?.id;
    final isCredit = _showPayment && received < totals.total;
    if (!_isEdit &&
        resolvedPartyId == null &&
        isCredit &&
        typedName.isNotEmpty) {
      final partyType = _isPurchase ? 'supplier' : 'customer';
      final partyRepo = PartyRepository();
      final matches =
          await partyRepo.getParties(type: partyType, search: typedName);
      final exact = matches
          .where((p) => p.name.toLowerCase() == typedName.toLowerCase());
      if (exact.isNotEmpty) {
        resolvedPartyId = exact.first.id;
      } else {
        resolvedPartyId = await partyRepo.insert(Party(
          name: typedName,
          partyType: partyType,
          phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
          gstin: _trimOrNull(_gstin),
          billingAddress: _trimOrNull(_address),
          billingState: _supplyState,
        ));
      }
    }

    // When still no party is linked (cash walk-in, or a non-billed doc), persist
    // whatever was typed as a free-text billing name so a one-off party still
    // names the document without creating a party record. Ignored once a party
    // is linked (its name is authoritative via the join).
    final oneOff = resolvedPartyId == null; // free-text (no party) document
    final txn = Transaction(
      id: widget.existingId,
      partyId: resolvedPartyId,
      billingName: oneOff && typedName.isNotEmpty ? typedName : null,
      billingGstin: oneOff ? _trimOrNull(_gstin) : null,
      billingAddress: oneOff ? _trimOrNull(_address) : null,
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
      ewayBillNumber: _isSale ? _trimOrNull(_ewayBill) : null,
      // The State of Supply (the tax-wired dropdown that decides IGST vs
      // CGST+SGST) is what prints in the "Place of Supply" slot on the Format 1
      // invoice and Format 2 estimate — there is no separate free-text field.
      placeOfSupply: (_isSale || _isEstimate)
          ? ((_supplyState?.trim().isEmpty ?? true) ? null : _supplyState!.trim())
          : null,
      transportName: _isSale ? _trimOrNull(_transportName) : null,
      vehicleNumber: _isSale ? _trimOrNull(_vehicleNumber) : null,
      deliveryDate: _isSale ? _deliveryDate?.toIso8601String() : null,
      deliveryLocation: _isSale ? _trimOrNull(_deliveryLocation) : null,
      shippingAddress: _isSale && _shippingDiff ? _trimOrNull(_shipAddress) : null,
      shippingCity: _isSale && _shippingDiff ? _trimOrNull(_shipCity) : null,
      shippingState: _isSale && _shippingDiff ? _shipState : null,
      shippingPincode:
          _isSale && _shippingDiff ? _trimOrNull(_shipPincode) : null,
      isShippingDiff: _isSale && _shippingDiff,
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
        // The number is minted atomically inside the insert transaction for
        // every auto-numbered type (sale, purchase, estimate, challan, returns,
        // orders) — this is what prevents two saves from claiming the same
        // number. A user-overridden number is authoritative as-is, so we pass
        // null and the typed value on [txn] is stored verbatim (no counter move,
        // so the running sequence keeps no gap for a number never auto-used).
        final mintType = _numberOverridden ? null : txnType;
        savedId = await repo.create(
          txn,
          items,
          initialPayment: payment,
          mintType: mintType,
        );
      }
      ref.refreshTransactions();
      if (!mounted) return null;
      _snack('$_typeLabel saved');
      if (andNew && !_isEdit) {
        await _resetForNew();
      } else if (pop) {
        if (!mounted) return savedId;
        setState(() => _saved = true);
        // A newly created sale invoice or estimate opens the full-screen
        // preview (WhatsApp / Share / Print) via pushReplacement, so Back from
        // the preview returns to the list rather than this form. Other docs
        // (and edits) simply pop back to their list.
        if ((txnType == TxnTypes.sale || txnType == TxnTypes.estimate) &&
            !_isEdit) {
          ref.refreshTransactions();
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(
              builder: (_) => BillPreviewScreen(transactionId: savedId),
            ),
          );
        } else {
          Navigator.pop(context, true);
        }
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
        // Credit-note number is minted atomically inside the insert (sale_return
        // now holds its own reserved counter), unless the user overrode it.
        savedId = await repo.create(txn, items,
            initialPayment: payment,
            mintType: _numberOverridden ? null : TxnTypes.saleReturn);
      }

      ref.refreshTransactions();
      if (!mounted) return null;
      _snack('Credit Note saved');
      if (andNew && !_isEdit) {
        await _resetForNew();
      } else if (pop) {
        setState(() => _saved = true);
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
    // Share / open / save always produce the single Original copy for a sale
    // invoice (the 3-copy set is print-only). Other documents are unlabelled.
    return InvoiceFormatRegistry.generate(
      docType: _docType(txn.transactionType),
      transaction: txn,
      items: items,
    );
  }

  /// Maps a transaction type to the format-registry document category.
  static DocumentType _docType(String txnType) => switch (txnType) {
        TxnTypes.estimate => DocumentType.estimate,
        TxnTypes.purchase => DocumentType.purchase,
        _ => DocumentType.sale,
      };

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
      // Sale invoices print as a 3-copy set (Original / Transporter / Office).
      // Other documents print the single-page PDF unchanged.
      if (_isSale) {
        final labels = await PrintCopiesSheet.show(context);
        if (labels == null || !mounted) return; // cancelled
        if (labels.isEmpty) {
          _snack('Select at least one copy to print');
          return;
        }
        final repo = ref.read(transactionRepositoryProvider);
        final txn = await repo.getById(id);
        final items = await repo.getItems(id);
        if (txn == null || !mounted) return;
        await Printing.layoutPdf(
          onLayout: (_) => InvoiceFormatRegistry.generateAllCopies(
            transaction: txn,
            items: items,
            labels: labels,
          ),
        );
      } else {
        await Printing.layoutPdf(onLayout: (_) => _buildPdf(id));
      }
    } catch (e) {
      if (mounted) _snack('Could not print: $e');
    }
  }


  /// Saves the document (without leaving the screen) and then opens a
  /// full-screen preview of its PDF.
  Future<void> _saveAndOpenPdf() async {
    if (_saving) return;
    final id = await _save(pop: false);
    if (id == null || !mounted) return;
    final fileName =
        '${_txnNumber.replaceAll(RegExp(r'[^\w\-]'), '_')}.pdf';
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(_txnNumber)),
          body: PdfPreview(
            build: (_) => _buildPdf(id),
            canChangePageFormat: false,
            canChangeOrientation: false,
            pdfFileName: fileName,
          ),
        ),
      ),
    );
  }

  /// Saves the document (without leaving the screen), writes its PDF to a temp
  /// file, and opens the system share/save sheet so the user can store it.
  Future<void> _saveAndSavePdf() async {
    if (_saving) return;
    final id = await _save(pop: false);
    if (id == null || !mounted) return;
    try {
      final bytes = await _buildPdf(id);
      final name = '${_txnNumber.replaceAll(RegExp(r'[^\w\-]'), '_')}.pdf';
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, name));
      await file.writeAsBytes(bytes);
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], text: 'Save $_txnNumber'),
      );
    } catch (e) {
      if (mounted) _snack('Could not save PDF: $e');
    }
  }

  /// Saves the current document, then opens a fresh form pre-filled from it so
  /// the user can record a near-identical document. Mirrors the saved-bill
  /// "Duplicate" action.
  Future<void> _saveAndDuplicate() async {
    if (_saving) return;
    final id = await _save(pop: false);
    if (id == null || !mounted) return;
    final r = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => AddEditTransactionScreen(
            mode: widget.mode, duplicateFromId: id),
      ),
    );
    if (r == true) ref.refreshTransactions();
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
      _received.clear();
      _ewayBill.clear();
      _transportName.clear();
      _vehicleNumber.clear();
      _deliveryLocation.clear();
      _deliveryDate = null;
      _transportExpanded = false;
      _shippingDiff = false;
      _shipAddress.clear();
      _shipCity.clear();
      _shipPincode.clear();
      _shipState = null;
      _date = DateTime.now();
      _dueDate = null;
      _invoiceDate = null;
      _saving = false;
      _txnNumber = next;
      _numberCtrl.text = next;
      _lastGoodNumber = next;
      // Reset the override baseline so the next entry starts on the auto number.
      _autoNumber = next;
    });
  }

  void _snack(String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  /// Trimmed controller text, or null when empty — for optional text columns.
  static String? _trimOrNull(TextEditingController c) {
    final t = c.text.trim();
    return t.isEmpty ? null : t;
  }

  // ── Discard-on-back guard ───────────────────────────────────────────────────

  /// Whether the user has entered anything worth confirming before leaving.
  /// While editing an existing document we always guard, since any change there
  /// is an edit to real data.
  bool get _isDirty {
    if (_isEdit) return true;
    if (_lines.isNotEmpty) return true;
    if (_party != null) return true;
    if (_billingName.text.trim().isNotEmpty) return true;
    if (_phone.text.trim().isNotEmpty) return true;
    if (_notes.text.trim().isNotEmpty) return true;
    if (_reference.text.trim().isNotEmpty) return true;
    if (_manualTotal.text.trim().isNotEmpty) return true;
    if (_manualPaid.text.trim().isNotEmpty) return true;
    if (_numberOverridden) return true;
    return false;
  }

  /// Asks the user to confirm leaving with unsaved changes. Returns true if it
  /// is OK to pop (nothing entered, or the user chose to discard).
  Future<bool> _confirmDiscard() async {
    if (_saving) return false;
    if (!_isDirty) return true;
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Discard $_typeLabel?'),
        content: Text(
            'You have unsaved changes. Are you sure you want to discard this $_typeLabel?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep Editing'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.primary),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return discard ?? false;
  }

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

    return PopScope(
      canPop: _saved,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final navigator = Navigator.of(context);
        if (await _confirmDiscard()) {
          navigator.pop();
        }
      },
      child: WideShellScaffold(
      child: Scaffold(
      backgroundColor: AppColors.surface(context),
      appBar: AppBar(
        backgroundColor: AppColors.surface(context),
        foregroundColor: AppColors.textPrimaryOf(context),
        elevation: 0,
        scrolledUnderElevation: 0,
        shape: Border(bottom: BorderSide(color: AppColors.dividerOf(context))),
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
      body: Stack(
        children: [
          _isCreditNote
          ? _creditNoteBody()
          : (Responsive.isWide(context)
              ? _wideBody(totals, totalQty)
              : ListView(
        padding: EdgeInsets.zero,
        children: [
          if (_canScanBill) _scanBillBanner(),
          _invoiceHeaderRow(),
          Divider(height: 1, thickness: 6, color: AppColors.background(context)),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: _billingFields(),
          ),
          if (_isSale) _shippingAndTransportSection(),
          const SizedBox(height: 12),
          _billedItemsSection(totals, totalQty),
          const SizedBox(height: 16),
          _totalAmountBar(totals.total),
          // Credit mode: editable Received + live Balance Due. Cash mode hides
          // both (the total is fully paid, no balance).
          if (_showPayment && !_isCash) _receivedSection(totals.total),
          if (_showPayment) _paymentSection(),
          _extraFields(),
          const SizedBox(height: 24),
        ],
      )),
          if (_scanning) _scanningOverlay(),
        ],
      ),
      bottomNavigationBar: _bottomBar(),
      ),
      ),
    );
  }

  /// Wide (Windows / desktop) layout for the sale/purchase form. A compact,
  /// space-efficient 3-section design that uses the horizontal width:
  ///   1. TOP — merged Invoice + Billing + Payment (no inner card borders),
  ///      fields laid out side-by-side in rows; optional Ship-To.
  ///   2. MIDDLE — line items as a one-row-per-item table + running totals.
  ///   3. BOTTOM — Transport / Delivery / Notes, also in compact rows.
  /// Android and any narrow window keep the original single-column ListView.
  Widget _wideBody(TxnTotals totals, double totalQty) {
    // Left-aligned (hugs the side rail) and wider, so the form uses the
    // horizontal space instead of floating centred with large side margins.
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1400),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          children: [
            if (_canScanBill) ...[
              _scanBillBanner(),
              const SizedBox(height: 16),
            ],
            _wideTopSection(totals),
            const SizedBox(height: 20),
            _wideItemsSection(totals, totalQty),
            const SizedBox(height: 20),
            _wideBottomSection(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  // ── Wide Section 1: Invoice + Billing + Payment (merged, borderless) ────────

  Widget _wideTopSection(TxnTotals totals) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _wideHeading(_isEstimate
            ? 'Estimate Details'
            : _isChallan
                ? 'Challan Details'
                : 'Invoice Details'),
        // Row 1: Invoice No. | Date | Phone
        _row3(
          _inlineNumberField(),
          _wideDateField(),
          _compactField(_phone, 'Phone Number',
              keyboardType: TextInputType.phone),
        ),
        const SizedBox(height: 12),
        // Row 2: Billing Name | GSTIN | Address
        _row3(
          BillingNameField(
            partyType: _isPurchase ? 'supplier' : 'customer',
            controller: _billingName,
            label: _isPurchase ? 'Supplier Name' : 'Billing Name (Optional)',
            onPartySelected: _onPartySelected,
            onTextChanged: _onBillingNameTyped,
          ),
          _compactField(_gstin, 'GSTIN',
              capitalization: TextCapitalization.characters),
          _compactField(_address, 'Address'),
        ),
        const SizedBox(height: 12),
        // Row 3: State of Supply | Payment Type | Deposit-to (non-sale) / blank
        _row3(
          _wideStateOfSupply(),
          _showPayment ? _widePaymentType() : const SizedBox.shrink(),
          (!_isSale && _showPayment)
              ? _wideDepositTo()
              : const SizedBox.shrink(),
        ),
        if (_interState)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: const [
                Icon(Icons.info_outline, size: 14, color: AppColors.partial),
                SizedBox(width: 6),
                Text('Inter-state supply — IGST applies',
                    style: TextStyle(fontSize: 12, color: AppColors.partial)),
              ],
            ),
          ),
        // Received + Balance Due now render below the Total Amount bar in the
        // items section (see [_wideItemsSection]), not here above the items.
        // Ship To (sale only).
        if (_isSale) ...[
          const SizedBox(height: 12),
          _shippingAndTransportSection(shippingOnly: true),
        ],
      ],
    );
  }

  // ── Wide Section 2: Item table ──────────────────────────────────────────────

  Widget _wideItemsSection(TxnTotals totals, double totalQty) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _wideHeading('Items'),
        // Column header row.
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: const [
              Expanded(flex: 34, child: _ColHead('Item Name')),
              SizedBox(width: 6),
              Expanded(flex: 9, child: _ColHead('Qty')),
              SizedBox(width: 6),
              Expanded(flex: 11, child: _ColHead('Unit')),
              SizedBox(width: 6),
              Expanded(flex: 12, child: _ColHead('Price/Unit')),
              SizedBox(width: 6),
              Expanded(flex: 13, child: _ColHead('Tax %')),
              SizedBox(width: 6),
              Expanded(flex: 11, child: _ColHead('Disc')),
              SizedBox(width: 6),
              Expanded(
                  flex: 13,
                  child: _ColHead('Amount', align: TextAlign.right)),
              SizedBox(width: 4),
              SizedBox(width: 40, child: _ColHead('Incl.')),
              SizedBox(width: 48),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_lines.isEmpty)
          const Padding(
            padding: EdgeInsets.all(20),
            child: Center(
              child: Text('No items added',
                  style: TextStyle(color: AppColors.textSecondary)),
            ),
          ),
        for (var i = 0; i < _lines.length; i++)
          ItemRowWidget(
            key: ObjectKey(_lines[i]),
            index: i + 1,
            draft: _lines[i],
            taxRates: _taxRates,
            isPurchase: _isPurchase,
            interState: _interState,
            onChanged: () => setState(() {}),
            onRemove: () => setState(() => _lines.removeAt(i)),
            onItemPicked: (item) async {
              final draft = await _draftFromItem(item);
              if (!mounted) return;
              setState(() => _lines[i] = draft);
            },
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add_circle, color: AppColors.partial),
            label: const Text('Add Items',
                style: TextStyle(
                    color: AppColors.partial, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              side: const BorderSide(color: AppColors.border),
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _addBlankLine,
          ),
        ),
        const SizedBox(height: 12),
        _totalAmountBar(totals.total),
        // Credit mode: editable Received + live Balance Due, directly below the
        // Total Amount bar (moved here from the top section, above the items).
        if (_showPayment && !_isCash) ...[
          const SizedBox(height: 4),
          _receivedSection(totals.total),
        ],
      ],
    );
  }

  // ── Wide Section 3: Transport / Delivery / Notes ────────────────────────────

  Widget _wideBottomSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _wideHeading('Transport, Delivery & Notes'),
        if (_isSale) ...[
          // E-Way Bill | Transport Name | Vehicle Number
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _compactField(_ewayBill, 'E-Way Bill Number')),
              const SizedBox(width: 16),
              Expanded(child: _compactField(_transportName, 'Transport Name')),
              const SizedBox(width: 16),
              Expanded(
                child: _compactField(_vehicleNumber, 'Vehicle Number',
                    capitalization: TextCapitalization.characters),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Delivery Date | Delivery Location
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _wideDeliveryDateField()),
              const SizedBox(width: 16),
              Expanded(child: _compactField(_deliveryLocation, 'Delivery Location')),
            ],
          ),
          const SizedBox(height: 12),
        ],
        // Description | Reference No.
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _notes,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'Add Note',
                  alignLabelWithHint: true,
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _isCreditNote
                  ? const SizedBox.shrink()
                  : _compactField(
                      _reference,
                      _isPurchase ? 'Supplier Invoice No.' : 'Reference No.'),
            ),
          ],
        ),
        if (_isEstimate) ...[
          const SizedBox(height: 8),
          _dateTile('Due Date', _dueDate, (d) => setState(() => _dueDate = d),
              clearable: true),
        ],
      ],
    );
  }

  // ── Wide layout shared helpers ──────────────────────────────────────────────

  /// Light section heading for the borderless wide sections.
  Widget _wideHeading(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(text,
              style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textSecondary)),
          const SizedBox(height: 6),
          Divider(height: 1, color: AppColors.dividerOf(context)),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  /// Lays three fields side by side with even spacing (wide layout). Pass
  /// `SizedBox.shrink()` for an empty slot to keep the others aligned.
  Widget _row3(Widget a, Widget b, Widget c) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: a),
        const SizedBox(width: 16),
        Expanded(child: b),
        const SizedBox(width: 16),
        Expanded(child: c),
      ],
    );
  }

  /// Shared content padding for every wide-layout row field (text fields and
  /// dropdowns alike) so they all render at the same height. The dropdowns
  /// additionally clamp their inner row to [_kWideFieldLineHeight] so a
  /// DropdownButton's larger intrinsic height doesn't make it taller than a
  /// single-line text field that shares this padding.
  static const EdgeInsets _kWideFieldPadding =
      EdgeInsets.symmetric(horizontal: 10, vertical: 12);

  /// Height of a single 14px text line, used to clamp the dropdowns' inner
  /// content so dropdown boxes match the text fields exactly.
  static const double _kWideFieldLineHeight = 19;

  /// Compact outlined text field for the wide layout rows.
  Widget _compactField(
    TextEditingController controller,
    String label, {
    TextInputType? keyboardType,
    TextCapitalization capitalization = TextCapitalization.none,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboardType,
      textCapitalization: capitalization,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: _kWideFieldPadding,
        border: const OutlineInputBorder(),
      ),
    );
  }

  /// Date field styled like [_compactField], opening the date picker on tap.
  Widget _wideDateField() {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _date,
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) setState(() => _date = picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Date',
          isDense: true,
          contentPadding: _kWideFieldPadding,
          border: OutlineInputBorder(),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(Formatters.date(_date.toIso8601String()),
                style: const TextStyle(fontSize: 14)),
            const Icon(Icons.calendar_today,
                size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  /// Delivery-date field (clearable) styled like [_compactField].
  Widget _wideDeliveryDateField() {
    return InkWell(
      onTap: () async {
        final picked = await showDatePicker(
          context: context,
          initialDate: _deliveryDate ?? DateTime.now(),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        );
        if (picked != null) setState(() => _deliveryDate = picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(
          labelText: 'Delivery Date',
          isDense: true,
          contentPadding: _kWideFieldPadding,
          border: OutlineInputBorder(),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _deliveryDate == null
                  ? 'Not set'
                  : Formatters.date(_deliveryDate!.toIso8601String()),
              style: TextStyle(
                  fontSize: 14,
                  color: _deliveryDate == null
                      ? AppColors.textHint
                      : AppColors.textPrimaryOf(context)),
            ),
            if (_deliveryDate != null)
              GestureDetector(
                onTap: () => setState(() => _deliveryDate = null),
                child: const Icon(Icons.clear,
                    size: 18, color: AppColors.textSecondary),
              )
            else
              const Icon(Icons.calendar_today,
                  size: 16, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  /// State-of-Supply dropdown as a compact outlined field (wide layout). Wired
  /// to [_supplyState] exactly like the mobile section.
  Widget _wideStateOfSupply() {
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'State of Supply',
        isDense: true,
        contentPadding: _kWideFieldPadding,
        border: OutlineInputBorder(),
      ),
      child: SizedBox(
        height: _kWideFieldLineHeight,
        child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: AppLists.indianStates.contains(_supplyState)
              ? _supplyState
              : null,
          isExpanded: true,
          isDense: true,
          hint: const Text('Select State',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 14)),
          icon: const Icon(Icons.keyboard_arrow_down,
              color: AppColors.textSecondary),
          items: AppLists.indianStates
              .map((s) => DropdownMenuItem(
                  value: s,
                  child:
                      Text(s, style: const TextStyle(fontSize: 14))))
              .toList(),
          onChanged: (v) => setState(() => _supplyState = v),
        ),
        ),
      ),
    );
  }

  /// Payment-type (mode) dropdown as a compact outlined field (wide layout).
  Widget _widePaymentType() {
    final modes = ref.watch(paymentModesProvider);
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Payment Type',
        isDense: true,
        contentPadding: _kWideFieldPadding,
        border: OutlineInputBorder(),
      ),
      child: SizedBox(
        height: _kWideFieldLineHeight,
        child: modes.when(
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
        data: (list) {
          _paymentModeId ??= list.where((m) => m.type == 'cash').firstOrNull?.id;
          return DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              value: _paymentModeId,
              isExpanded: true,
              isDense: true,
              icon: const Icon(Icons.keyboard_arrow_down,
                  color: AppColors.textSecondary),
              items: list
                  .map((m) => DropdownMenuItem(
                        value: m.id,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.currency_rupee,
                                size: 14, color: AppColors.accent),
                            const SizedBox(width: 4),
                            Text(m.name,
                                style: const TextStyle(fontSize: 14)),
                          ],
                        ),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _paymentModeId = v),
            ),
          );
        },
      ),
      ),
    );
  }

  /// "Deposit to" account dropdown (non-sale docs), compact wide variant.
  Widget _wideDepositTo() {
    final accounts = ref.watch(accountsProvider);
    accounts.whenData((list) {
      _accountId ??=
          list.where((a) => a.isDefault).firstOrNull?.id ?? list.firstOrNull?.id;
    });
    return InputDecorator(
      decoration: const InputDecoration(
        labelText: 'Deposit to',
        isDense: true,
        contentPadding: _kWideFieldPadding,
        border: OutlineInputBorder(),
      ),
      child: SizedBox(
        height: _kWideFieldLineHeight,
        child: accounts.when(
        loading: () => const SizedBox.shrink(),
        error: (_, _) => const SizedBox.shrink(),
        data: (list) => DropdownButtonHideUnderline(
          child: DropdownButton<int>(
            value: _accountId,
            isExpanded: true,
            isDense: true,
            icon: const Icon(Icons.keyboard_arrow_down,
                color: AppColors.textSecondary),
            items: list
                .map((a) => DropdownMenuItem(
                    value: a.id,
                    child: Text(a.name, style: const TextStyle(fontSize: 14))))
                .toList(),
            onChanged: (v) => setState(() => _accountId = v),
          ),
        ),
      ),
      ),
    );
  }

  /// Tappable banner at the top of the Purchase form that launches the scan.
  Widget _scanBillBanner() {
    return InkWell(
      onTap: _scanning ? null : _scanBill,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.partial.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.partial.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            const Icon(Icons.document_scanner_outlined,
                color: AppColors.partial),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Scan Bill',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                          color: AppColors.partial)),
                  Text('or fill manually below',
                      style: TextStyle(
                          fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.partial),
          ],
        ),
      ),
    );
  }

  /// Full-screen dim + spinner shown while ML Kit reads the bill.
  Widget _scanningOverlay() {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            decoration: BoxDecoration(
              color: AppColors.surface(context),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(color: AppColors.partial),
                SizedBox(height: 16),
                Text('Reading bill…',
                    style: TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
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
        Divider(height: 1, thickness: 6, color: AppColors.background(context)),
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
            child: GestureDetector(
              onTap: _editNumber,
              child: _labelledValue('Return No.', _txnNumber, chevron: true),
            ),
          ),
          Container(
            width: 1,
            height: 36,
            color: AppColors.dividerOf(context),
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
                    : AppColors.textPrimaryOf(context),
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
      color: AppColors.background(context),
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
                color: labelColor ?? AppColors.textPrimaryOf(context))),
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

  /// Three-dots menu shown on every sale-document creation screen. It mirrors
  /// the action set offered on a saved bill (Duplicate + the PDF actions), but
  /// because the document isn't persisted yet each item saves it first (staying
  /// on-screen via `_save(pop: false)`) and then acts on the saved PDF.
  Widget _overflowMenu() {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_vert),
      tooltip: 'More',
      onSelected: (v) async {
        switch (v) {
          case 'duplicate':
            await _saveAndDuplicate();
          case 'open_pdf':
            await _saveAndOpenPdf();
          case 'print_pdf':
            await _saveAndPrint();
          case 'share_pdf':
            await _saveAndShare();
          case 'save_pdf':
            await _saveAndSavePdf();
        }
      },
      itemBuilder: (_) => [
        _menuItem('duplicate', Icons.copy_outlined, 'Duplicate'),
        _menuItem('open_pdf', Icons.picture_as_pdf_outlined, 'Open PDF'),
        _menuItem('print_pdf', Icons.print_outlined, 'Print PDF'),
        _menuItem('share_pdf', Icons.share_outlined, 'Share PDF'),
        _menuItem('save_pdf', Icons.download_outlined, 'Save PDF to Phone'),
      ],
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label) {
    return PopupMenuItem<String>(
      value: value,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(label),
      ),
    );
  }

  // ── Header: Credit / Cash toggle ────────────────────────────────────────────

  Widget _creditCashToggle() {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: AppColors.background(context),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppColors.dividerOf(context)),
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
            child: Responsive.isWide(context)
                ? _inlineNumberField()
                : GestureDetector(
                    onTap: _editNumber,
                    child: _labelledValue(
                      _isEstimate
                          ? 'Estimate No.'
                          : _isChallan
                              ? 'Challan No.'
                              : 'Invoice No.',
                      _txnNumber,
                      chevron: true,
                    ),
                  ),
          ),
          Container(
            width: 1,
            height: 36,
            color: AppColors.dividerOf(context),
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

  /// Inline-editable document number for the wide layout — the user types the
  /// number directly in the header (no dialog). Commits on submit / focus loss
  /// via [_commitInlineNumber], which validates uniqueness.
  Widget _inlineNumberField() {
    final label = _isEstimate
        ? 'Estimate No.'
        : _isChallan
            ? 'Challan No.'
            : 'Invoice No.';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label,
            style:
                const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
        TextField(
          controller: _numberCtrl,
          focusNode: _numberFocus,
          textCapitalization: TextCapitalization.characters,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _commitInlineNumber(),
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: 6),
            enabledBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.border)),
            focusedBorder: UnderlineInputBorder(
                borderSide: BorderSide(color: AppColors.primary, width: 1.5)),
          ),
        ),
      ],
    );
  }

  /// Lets the user override the document number (e.g. type `K/100` instead of
  /// the auto-generated `INV-0001`). The override is saved on this document only;
  /// the running counter is untouched, so the next new document continues the
  /// normal sequence. Blank input restores the auto-generated number. Validates
  /// the chosen number isn't already used by another (non-deleted) document.
  Future<void> _editNumber() async {
    final label = _isEstimate
        ? 'Estimate No.'
        : _isChallan
            ? 'Challan No.'
            : _isCreditNote
                ? 'Return No.'
                : 'Invoice No.';
    final result = await editDocumentNumber(
      context,
      label: label,
      current: _txnNumber,
      excludeId: widget.existingId,
      repo: ref.read(transactionRepositoryProvider),
    );
    if (result != null) setState(() => _txnNumber = result);
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
        BillingNameField(
          partyType: _isPurchase ? 'supplier' : 'customer',
          controller: _billingName,
          label: _isPurchase ? 'Supplier Name' : 'Billing Name (Optional)',
          onPartySelected: _onPartySelected,
          onTextChanged: _onBillingNameTyped,
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
      color: AppColors.background(context),
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

  // ── Received + Balance Due (Credit mode only) ───────────────────────────────

  /// Editable Received row + live, read-only Balance Due (Total − Received).
  /// Shown only in Credit mode; in Cash mode the invoice is paid in full so
  /// neither row is rendered. Received defaults to empty (₹0).
  Widget _receivedSection(double total) {
    final received =
        (double.tryParse(_received.text.trim()) ?? 0).clamp(0, total).toDouble();
    final balance = total - received;

    return Container(
      color: AppColors.background(context),
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        children: [
          _summaryRow('Received', _editableAmountField(_received)),
          const SizedBox(height: 4),
          _summaryRow(
            'Balance Due',
            Text(Formatters.currency(balance),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.paid)),
            labelColor: AppColors.paid,
          ),
        ],
      ),
    );
  }

  /// Applies a saved party chosen from the billing-name dropdown: fills name /
  /// phone and auto-fills the supply state.
  void _onPartySelected(Party p) {
    setState(() {
      _party = p;
      _billingName.text = p.name;
      if ((p.phone ?? '').isNotEmpty) _phone.text = p.phone!;
      // Prefill GSTIN / address from the party (editable below).
      _gstin.text = p.gstin ?? '';
      _address.text = p.billingAddress ?? '';
      // Auto-fill supply state from party; user can still override below.
      if ((p.billingState ?? '').isNotEmpty) {
        _supplyState = p.billingState;
      }
    });
  }

  /// Called when the billing name is typed by hand. Once the text no longer
  /// matches the selected party's name, clear the link so the document is
  /// treated as a one-off (free-text) party — saved on the invoice via
  /// billing_name, without creating a party record.
  void _onBillingNameTyped(String value) {
    if (_party != null && value.trim() != _party!.name) {
      setState(() => _party = null);
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
          // "Deposit to" (account selector) is intentionally omitted from the
          // Sale form. It remains available on Purchase and other docs.
          if (!_isSale) ...[
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
          ],
          // ── State of Supply ──────────────────────────────────────────────
          // Label keeps its natural one-line width on the left; the dropdown
          // takes the rest of the row (isExpanded) so its arrow sits at the far
          // right edge and the "Select State" hint can't crowd the label.
          Row(
            children: [
              const Text('State of Supply', style: TextStyle(fontSize: 15)),
              const SizedBox(width: 16),
              Expanded(
                child: DropdownButton<String>(
                  value: AppLists.indianStates.contains(_supplyState)
                      ? _supplyState
                      : null,
                  isExpanded: true,
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
          Divider(height: 1, thickness: 6, color: AppColors.background(context)),
        ],
      ),
    );
  }

  // ── Bottom action bar ───────────────────────────────────────────────────────

  Widget _bottomBar() {
    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surface(context),
          border: Border(top: BorderSide(color: AppColors.dividerOf(context))),
        ),
        child: Row(
          children: [
            Expanded(
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  foregroundColor: AppColors.textPrimaryOf(context),
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

  // ── Invoice Format 1: Shipping address + Transport & Delivery (sale only) ────

  /// Shipping-address toggle + collapsible Transport & Delivery section. Shown
  /// only on the Sale Invoice form. Both are entirely optional and feed the
  /// Format 1 invoice PDF (transport grid in the header, ship-to block).
  ///
  /// [shippingOnly] (wide layout) renders just the Ship-To toggle + fields; the
  /// transport fields are placed in the wide bottom section instead, so they
  /// aren't duplicated.
  Widget _shippingAndTransportSection({bool shippingOnly = false}) {
    return Padding(
      padding: shippingOnly
          ? EdgeInsets.zero
          : const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Shipping address toggle.
          CheckboxListTile(
            value: _shippingDiff,
            onChanged: (v) => setState(() => _shippingDiff = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Shipping address is different from billing',
                style: TextStyle(fontSize: 14)),
          ),
          if (_shippingDiff) ...[
            const SizedBox(height: 8),
            TextField(
              controller: _shipAddress,
              decoration: const InputDecoration(
                labelText: 'Shipping Address',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            // City | Pincode | State on one compact line.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _shipCity,
                    decoration: const InputDecoration(
                      labelText: 'City',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _shipPincode,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Pincode',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: AppLists.indianStates.contains(_shipState)
                        ? _shipState
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'State',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: AppLists.indianStates
                        .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                        .toList(),
                    onChanged: (v) => setState(() => _shipState = v),
                  ),
                ),
              ],
            ),
          ],
          // Transport & Delivery Details. Skipped in shippingOnly mode (wide
          // layout shows them in the bottom section instead). On narrow (mobile)
          // they stay tucked in a collapsible ExpansionTile to save space.
          if (shippingOnly)
            const SizedBox.shrink()
          else ...[
            const SizedBox(height: 4),
            if (Responsive.isWide(context)) ...[
              const Padding(
                padding: EdgeInsets.only(top: 4, bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Transport & Delivery Details',
                      style:
                          TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
              ..._transportFields(),
            ] else
            Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(bottom: 8),
                initiallyExpanded: _transportExpanded,
                onExpansionChanged: (v) => _transportExpanded = v,
                title: const Text('Transport & Delivery Details',
                    style:
                        TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                children: _transportFields(),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The Transport & Delivery input fields (E-Way Bill, Transport Name,
  /// Vehicle Number, Delivery Date, Delivery Location). Shared
  /// between the always-expanded wide layout and the collapsible mobile one.
  List<Widget> _transportFields() {
    return [
      TextField(
        controller: _ewayBill,
        decoration: const InputDecoration(
          labelText: 'E-Way Bill Number',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _transportName,
        decoration: const InputDecoration(
          labelText: 'Transport Name',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _vehicleNumber,
        textCapitalization: TextCapitalization.characters,
        decoration: const InputDecoration(
          labelText: 'Vehicle Number',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      const SizedBox(height: 12),
      InkWell(
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: _deliveryDate ?? DateTime.now(),
            firstDate: DateTime(2000),
            lastDate: DateTime(2100),
          );
          if (picked != null) setState(() => _deliveryDate = picked);
        },
        child: InputDecorator(
          decoration: const InputDecoration(
            labelText: 'Delivery Date',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                _deliveryDate == null
                    ? 'Not set'
                    : Formatters.date(_deliveryDate!.toIso8601String()),
                style: TextStyle(
                  color: _deliveryDate == null
                      ? AppColors.textHint
                      : AppColors.textPrimaryOf(context),
                ),
              ),
              if (_deliveryDate != null)
                GestureDetector(
                  onTap: () => setState(() => _deliveryDate = null),
                  child: const Icon(Icons.clear,
                      size: 18, color: AppColors.textSecondary),
                )
              else
                const Icon(Icons.calendar_today,
                    size: 16, color: AppColors.textSecondary),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _deliveryLocation,
        decoration: const InputDecoration(
          labelText: 'Delivery Location',
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
    ];
  }

  Widget _extraFields() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_isEstimate) ...[
            _dateTile('Due Date', _dueDate,
                (d) => setState(() => _dueDate = d),
                clearable: true),
            const SizedBox(height: 8),
          ],
          // Notes are text only — no image/photo attachment (Invoice Format 1).
          TextField(
            controller: _notes,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Description',
              hintText: 'Add Note',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
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

/// Column header label for the wide item table.
class _ColHead extends StatelessWidget {
  final String text;
  final TextAlign align;
  const _ColHead(this.text, {this.align = TextAlign.left});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: align,
      style: const TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: AppColors.textSecondary,
      ),
    );
  }
}

