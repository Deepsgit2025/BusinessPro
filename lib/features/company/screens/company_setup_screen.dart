import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:signature/signature.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/providers/business_provider.dart';
import '../widgets/visiting_card.dart';

class CompanySetupScreen extends ConsumerStatefulWidget {
  const CompanySetupScreen({super.key});

  @override
  ConsumerState<CompanySetupScreen> createState() => _CompanySetupScreenState();
}

class _CompanySetupScreenState extends ConsumerState<CompanySetupScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  late final TabController _tabController;
  bool _loaded = false;

  // Basic details
  final _nameCtrl = TextEditingController();
  final _legalNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _altPhoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _gstinCtrl = TextEditingController();
  final _panCtrl = TextEditingController();
  final _addr1Ctrl = TextEditingController();
  final _addr2Ctrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _pincodeCtrl = TextEditingController();
  final _bankNameCtrl = TextEditingController();
  final _bankAccCtrl = TextEditingController();
  final _ifscCtrl = TextEditingController();
  final _upiCtrl = TextEditingController();
  final _invPrefixCtrl = TextEditingController(text: 'INV');
  final _purPrefixCtrl = TextEditingController(text: 'PUR');

  // Business details
  String? _state;
  String? _businessType;
  String? _businessCategory;
  DateTime? _booksBeginningDate;

  // Show-on-card toggles
  bool _showGstin = false;
  bool _showBusinessType = false;
  bool _showBusinessCategory = false;

  // Invoice print toggles (bank details + UPI QR). Default ON.
  bool _printBankOnInvoice = true;
  bool _printUpiQrOnInvoice = true;

  // Visuals
  String? _logoPath;
  String? _signaturePath;
  CardStyle _cardStyle = CardStyle.classic;

  final _cardKey = GlobalKey();
  final _cardPageCtrl = PageController(viewportFraction: 0.9);

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    for (final c in _allCtrls) {
      c.addListener(_onChanged);
    }
  }

  List<TextEditingController> get _allCtrls => [
        _nameCtrl, _legalNameCtrl, _phoneCtrl, _altPhoneCtrl, _emailCtrl, _gstinCtrl,
        _panCtrl, _addr1Ctrl, _addr2Ctrl, _cityCtrl, _pincodeCtrl, _bankNameCtrl,
        _bankAccCtrl, _ifscCtrl, _upiCtrl, _invPrefixCtrl, _purPrefixCtrl,
      ];

  void _onChanged() => setState(() {});

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _prefill();
    }
  }

  void _prefill() {
    final bizAsync = ref.read(businessProvider);
    bizAsync.whenData((biz) {
      if (biz == null) return;
      _nameCtrl.text = biz['name'] as String? ?? '';
      _legalNameCtrl.text = biz['legal_name'] as String? ?? '';
      _phoneCtrl.text = biz['phone'] as String? ?? '';
      _altPhoneCtrl.text = biz['alternate_phone'] as String? ?? '';
      _emailCtrl.text = biz['email'] as String? ?? '';
      _gstinCtrl.text = biz['gstin'] as String? ?? '';
      _panCtrl.text = biz['pan_number'] as String? ?? '';
      _addr1Ctrl.text = biz['address_line1'] as String? ?? '';
      _addr2Ctrl.text = biz['address_line2'] as String? ?? '';
      _cityCtrl.text = biz['city'] as String? ?? '';
      _pincodeCtrl.text = biz['pincode'] as String? ?? '';
      _bankNameCtrl.text = biz['bank_name'] as String? ?? '';
      _bankAccCtrl.text = biz['bank_account_no'] as String? ?? '';
      _ifscCtrl.text = biz['bank_ifsc'] as String? ?? '';
      _upiCtrl.text = biz['upi_id'] as String? ?? '';
      _invPrefixCtrl.text = biz['invoice_prefix'] as String? ?? 'INV';
      _purPrefixCtrl.text = biz['purchase_prefix'] as String? ?? 'PUR';
      _logoPath = biz['logo_path'] as String?;
      _signaturePath = biz['signature_path'] as String?;

      final st = biz['state'] as String?;
      _state = (st != null && _indianStates.contains(st)) ? st : null;
      final bt = biz['business_type'] as String?;
      _businessType = (bt != null && _businessTypes.contains(bt)) ? bt : null;
      final bc = biz['business_category'] as String?;
      _businessCategory = (bc != null && _businessCategories.contains(bc)) ? bc : null;

      final bbd = biz['books_beginning_date'] as String?;
      _booksBeginningDate = bbd != null ? DateTime.tryParse(bbd) : null;
      _booksBeginningDate ??= DateTime.now();

      _cardStyle = CardStyleX.fromId(biz['card_style'] as String?);
      _showGstin = (biz['show_gstin_on_card'] as int? ?? 0) == 1;
      _showBusinessType = (biz['show_business_type_on_card'] as int? ?? 0) == 1;
      _showBusinessCategory = (biz['show_business_category_on_card'] as int? ?? 0) == 1;

      _printBankOnInvoice = (biz['print_bank_on_invoice'] as int? ?? 1) == 1;
      _printUpiQrOnInvoice = (biz['print_upi_qr_on_invoice'] as int? ?? 1) == 1;

      // Jump the carousel to the saved style.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_cardPageCtrl.hasClients) {
          _cardPageCtrl.jumpToPage(_cardStyle.index);
        }
      });
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    _cardPageCtrl.dispose();
    for (final c in _allCtrls) {
      c.removeListener(_onChanged);
      c.dispose();
    }
    super.dispose();
  }

  // ── Completion % ─────────────────────────────────────────────

  /// Fields that count toward profile completion, mirroring Vyapar's
  /// "Profile X% complete" indicator.
  double get _completion {
    final checks = <bool>[
      _nameCtrl.text.trim().isNotEmpty,
      _phoneCtrl.text.trim().isNotEmpty,
      _emailCtrl.text.trim().isNotEmpty,
      _gstinCtrl.text.trim().isNotEmpty,
      (_addr1Ctrl.text.trim().isNotEmpty || _addr2Ctrl.text.trim().isNotEmpty),
      _logoPath != null,
      _state != null,
      _businessType != null,
      _businessCategory != null,
      _signaturePath != null,
      _bankNameCtrl.text.trim().isNotEmpty,
      _upiCtrl.text.trim().isNotEmpty,
    ];
    final done = checks.where((c) => c).length;
    return done / checks.length;
  }

  CardData get _cardData => CardData(
        name: _nameCtrl.text.trim(),
        phone: _phoneCtrl.text.trim(),
        email: _emailCtrl.text.trim(),
        address: _addr1Ctrl.text.trim(),
        logoPath: _logoPath,
        gstin: _showGstin ? _gstinCtrl.text.trim() : null,
        businessType: _showBusinessType ? _businessType : null,
        businessCategory: _showBusinessCategory ? _businessCategory : null,
      );

  // ── Image / signature pickers ────────────────────────────────

  Future<void> _pickLogo() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512);
    if (img != null) setState(() => _logoPath = img.path);
  }

  Future<void> _uploadSignature() async {
    final picker = ImagePicker();
    final img = await picker.pickImage(source: ImageSource.gallery, maxWidth: 1024);
    if (img != null) setState(() => _signaturePath = img.path);
  }

  Future<void> _drawSignature() async {
    final bytes = await showModalBottomSheet<Uint8List>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _SignaturePadSheet(),
    );
    if (bytes != null) {
      final dir = await getApplicationDocumentsDirectory();
      final dest = p.join(dir.path, 'BusinessPro', 'signature_${DateTime.now().millisecondsSinceEpoch}.png');
      await File(dest).writeAsBytes(bytes);
      setState(() => _signaturePath = dest);
    }
  }

  void _removeSignature() => setState(() => _signaturePath = null);

  Future<void> _pickBooksDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _booksBeginningDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _booksBeginningDate = picked);
  }

  // ── Share card ───────────────────────────────────────────────

  Future<void> _shareCard() async {
    try {
      final boundary = _cardKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final dir = await getTemporaryDirectory();
      final file = File(p.join(dir.path, 'visiting_card.png'));
      await file.writeAsBytes(byteData.buffer.asUint8List());

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path)],
          text: '${_nameCtrl.text.trim().isEmpty ? "My Company" : _nameCtrl.text.trim()} — visiting card',
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not share card: $e')),
        );
      }
    }
  }

  // ── Save ─────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) {
      // Make sure the user sees the offending field (it's on the Basic tab).
      _tabController.animateTo(0);
      return;
    }
    setState(() => _saving = true);
    await ref.read(businessProvider.notifier).save({
      'name': _nameCtrl.text.trim(),
      'legal_name': _legalNameCtrl.text.trim(),
      'phone': _phoneCtrl.text.trim(),
      'alternate_phone': _altPhoneCtrl.text.trim(),
      'email': _emailCtrl.text.trim(),
      'gstin': _gstinCtrl.text.trim().toUpperCase(),
      'pan_number': _panCtrl.text.trim().toUpperCase(),
      'address_line1': _addr1Ctrl.text.trim(),
      'address_line2': _addr2Ctrl.text.trim(),
      'city': _cityCtrl.text.trim(),
      'state': _state ?? '',
      'pincode': _pincodeCtrl.text.trim(),
      'business_type': _businessType ?? '',
      'business_category': _businessCategory ?? '',
      'books_beginning_date':
          (_booksBeginningDate ?? DateTime.now()).toIso8601String(),
      'bank_name': _bankNameCtrl.text.trim(),
      'bank_account_no': _bankAccCtrl.text.trim(),
      'bank_ifsc': _ifscCtrl.text.trim().toUpperCase(),
      'upi_id': _upiCtrl.text.trim(),
      'print_bank_on_invoice': _printBankOnInvoice ? 1 : 0,
      'print_upi_qr_on_invoice': _printUpiQrOnInvoice ? 1 : 0,
      'invoice_prefix': _invPrefixCtrl.text.trim().toUpperCase(),
      'purchase_prefix': _purPrefixCtrl.text.trim().toUpperCase(),
      'card_style': _cardStyle.id,
      'show_gstin_on_card': _showGstin ? 1 : 0,
      'show_business_type_on_card': _showBusinessType ? 1 : 0,
      'show_business_category_on_card': _showBusinessCategory ? 1 : 0,
      if (_logoPath != null) 'logo_path': _logoPath,
      'signature_path': _signaturePath,
    });
    setState(() => _saving = false);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Business profile saved'), backgroundColor: AppColors.primary),
      );
      Navigator.pop(context);
    }
  }

  // ── Build ────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final pct = (_completion * 100).round();
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(title: const Text('Business Profile')),
      body: Form(
        key: _formKey,
        child: NestedScrollView(
          headerSliverBuilder: (_, innerBoxIsScrolled) => [
            SliverToBoxAdapter(child: _cardCarousel()),
            SliverToBoxAdapter(child: _completionBar(pct)),
            SliverPersistentHeader(
              pinned: true,
              delegate: _TabBarDelegate(
                TabBar(
                  controller: _tabController,
                  labelColor: AppColors.primary,
                  indicatorColor: AppColors.primary,
                  tabs: const [
                    Tab(text: 'Basic Details'),
                    Tab(text: 'Business Details'),
                  ],
                ),
              ),
            ),
          ],
          body: TabBarView(
            controller: _tabController,
            children: [
              _basicDetailsTab(),
              _businessDetailsTab(),
            ],
          ),
        ),
      ),
      bottomNavigationBar: _bottomBar(),
    );
  }

  // ── Card carousel + share ────────────────────────────────────

  Widget _cardCarousel() {
    return Container(
      color: const Color(0xFFEAF1FB),
      padding: const EdgeInsets.only(top: 14, bottom: 8),
      child: Column(
        children: [
          SizedBox(
            height: 210,
            child: PageView.builder(
              controller: _cardPageCtrl,
              physics: const PageScrollPhysics(),
              itemCount: CardStyle.values.length,
              onPageChanged: (i) => setState(() => _cardStyle = CardStyle.values[i]),
              itemBuilder: (_, i) {
                final style = CardStyle.values[i];
                // Keying on the card data forces a rebuild whenever any
                // shown field or toggle changes, so the card reflects edits
                // (e.g. "Show on card") immediately.
                final card = VisitingCard(
                  key: ValueKey('$style-${_cardData.fingerprint}'),
                  data: _cardData,
                  style: style,
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Center(
                    // Only wrap the currently-selected card in the repaint
                    // boundary we capture for sharing.
                    child: style == _cardStyle
                        ? RepaintBoundary(key: _cardKey, child: card)
                        : card,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < CardStyle.values.length; i++)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  width: i == _cardStyle.index ? 18 : 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: i == _cardStyle.index ? AppColors.primary : AppColors.border,
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _shareCard,
            icon: const Icon(Icons.share, size: 18),
            label: const Text('Share Card'),
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
            ),
          ),
        ],
      ),
    );
  }

  Widget _completionBar(int pct) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Profile $pct% complete.',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _completion,
              minHeight: 6,
              backgroundColor: AppColors.border,
              valueColor: const AlwaysStoppedAnimation(AppColors.partial),
            ),
          ),
        ],
      ),
    );
  }

  // ── Tabs ─────────────────────────────────────────────────────

  Widget _basicDetailsTab() {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 24),
      children: [
        Center(
          child: GestureDetector(
            onTap: _pickLogo,
            child: Column(
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: AppColors.primary.withValues(alpha: 0.1),
                  backgroundImage: (_logoPath != null && File(_logoPath!).existsSync())
                      ? FileImage(File(_logoPath!))
                      : null,
                  child: (_logoPath == null || !File(_logoPath!).existsSync())
                      ? const Icon(Icons.add_a_photo, color: AppColors.primary, size: 28)
                      : null,
                ),
                const SizedBox(height: 6),
                const Text('Tap to add logo',
                    style: TextStyle(color: AppColors.textSecondary, fontSize: 12)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        _Field(_nameCtrl, 'Business Name *', required: true),
        _Field(_gstinCtrl, 'GSTIN', hint: '22AAAAA0000A1Z5'),
        _ShowOnCardToggle(
          value: _showGstin,
          onChanged: (v) => setState(() => _showGstin = v),
        ),
        _Field(_phoneCtrl, 'Phone Number 1', keyboardType: TextInputType.phone),
        _Field(_altPhoneCtrl, 'Phone Number 2', keyboardType: TextInputType.phone),
        _Field(_emailCtrl, 'Email', keyboardType: TextInputType.emailAddress),
        _Field(_legalNameCtrl, 'Legal / Registered Name'),
        _Field(_panCtrl, 'PAN Number'),

        const SizedBox(height: 8),
        _SectionHeader('Address'),
        _Field(_addr1Ctrl, 'Address Line 1'),
        _Field(_addr2Ctrl, 'Address Line 2'),
        Row(children: [
          Expanded(child: _Field(_cityCtrl, 'City')),
          const SizedBox(width: 12),
          Expanded(child: _Field(_pincodeCtrl, 'Pincode', keyboardType: TextInputType.number)),
        ]),

        const SizedBox(height: 8),
        _SectionHeader('Bank Details'),
        _InvoiceToggle(
          title: 'Print bank details on invoices',
          subtitle: 'Show bank name, account number & IFSC on the printed bill.',
          value: _printBankOnInvoice,
          onChanged: (v) => setState(() => _printBankOnInvoice = v),
        ),
        _InvoiceToggle(
          title: 'Print UPI QR code on invoices',
          subtitle:
              'A scan-to-pay QR (pre-filled with the bill amount) is added to the invoice.',
          value: _printUpiQrOnInvoice,
          onChanged: (v) => setState(() => _printUpiQrOnInvoice = v),
        ),
        const SizedBox(height: 8),
        _Field(_bankNameCtrl, 'Bank Name'),
        _Field(_bankAccCtrl, 'Account Number', keyboardType: TextInputType.number),
        _Field(_ifscCtrl, 'IFSC Code'),
        // UPI ID is only required for the QR; when the QR toggle is on we
        // validate its format so a malformed id never breaks QR generation.
        _Field(
          _upiCtrl,
          'UPI ID',
          hint: 'name@bank',
          validator: (v) {
            final text = v?.trim() ?? '';
            if (text.isEmpty) return null; // optional
            return _upiRegex.hasMatch(text) ? null : 'Enter a valid UPI ID (e.g. name@bank)';
          },
        ),

        const SizedBox(height: 8),
        _SectionHeader('Invoice Settings'),
        Row(children: [
          Expanded(child: _Field(_invPrefixCtrl, 'Invoice Prefix', hint: 'INV')),
          const SizedBox(width: 12),
          Expanded(child: _Field(_purPrefixCtrl, 'Purchase Prefix', hint: 'PUR')),
        ]),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _businessDetailsTab() {
    final dateFmt = DateFormat('dd/MM/yyyy');
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 24),
      children: [
        _Dropdown(
          label: 'State',
          value: _state,
          items: _indianStates,
          onChanged: (v) => setState(() => _state = v),
        ),
        _Dropdown(
          label: 'Business Type',
          value: _businessType,
          items: _businessTypes,
          onChanged: (v) => setState(() => _businessType = v),
        ),
        _ShowOnCardToggle(
          value: _showBusinessType,
          onChanged: (v) => setState(() => _showBusinessType = v),
        ),
        _Dropdown(
          label: 'Business Category',
          value: _businessCategory,
          items: _businessCategories,
          onChanged: (v) => setState(() => _businessCategory = v),
        ),
        _ShowOnCardToggle(
          value: _showBusinessCategory,
          onChanged: (v) => setState(() => _showBusinessCategory = v),
        ),
        const SizedBox(height: 8),
        InkWell(
          onTap: _pickBooksDate,
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Books Beginning Date',
              suffixIcon: Icon(Icons.calendar_today, size: 18),
            ),
            child: Text(
              _booksBeginningDate != null
                  ? dateFmt.format(_booksBeginningDate!)
                  : '',
            ),
          ),
        ),
        const SizedBox(height: 20),
        _SectionHeader('Signature'),
        _signatureBox(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _signatureBox() {
    final hasSig = _signaturePath != null && File(_signaturePath!).existsSync();
    return Column(
      children: [
        Container(
          height: 150,
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.border, style: BorderStyle.solid),
            color: AppColors.backgroundLight,
          ),
          child: hasSig
              ? Padding(
                  padding: const EdgeInsets.all(8),
                  child: Image.file(File(_signaturePath!), fit: BoxFit.contain),
                )
              : const Center(
                  child: Text('No signature added',
                      style: TextStyle(color: AppColors.textHint)),
                ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextButton(onPressed: _drawSignature, child: Text(hasSig ? 'Change' : 'Draw')),
            const SizedBox(width: 8),
            TextButton(onPressed: _uploadSignature, child: const Text('Upload')),
            const SizedBox(width: 8),
            TextButton(
              onPressed: hasSig ? _removeSignature : null,
              child: const Text('Remove'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _bottomBar() {
    return SafeArea(
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                foregroundColor: AppColors.textPrimary,
              ),
              child: const Text(AppStrings.cancel),
            ),
          ),
          Expanded(
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                shape: const RoundedRectangleBorder(),
              ),
              child: _saving
                  ? const SizedBox(
                      height: 20, width: 20,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text(AppStrings.save),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Signature drawing pad sheet ───────────────────────────────

class _SignaturePadSheet extends StatefulWidget {
  const _SignaturePadSheet();

  @override
  State<_SignaturePadSheet> createState() => _SignaturePadSheetState();
}

class _SignaturePadSheetState extends State<_SignaturePadSheet> {
  late final SignatureController _controller;

  @override
  void initState() {
    super.initState();
    _controller = SignatureController(
      penStrokeWidth: 3,
      penColor: Colors.black,
      exportBackgroundColor: Colors.white,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _done() async {
    if (_controller.isEmpty) {
      Navigator.pop(context);
      return;
    }
    final img = await _controller.toPngBytes();
    if (mounted) Navigator.pop(context, img);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('Draw your signature',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.border),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Signature(
              controller: _controller,
              height: 220,
              backgroundColor: const Color(0xFFFAFAFA),
            ),
          ),
          Row(
            children: [
              TextButton(
                onPressed: () => _controller.clear(),
                child: const Text('Clear'),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text(AppStrings.cancel),
              ),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _done, child: const Text('Done')),
              const SizedBox(width: 16),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

// ── Reusable widgets ──────────────────────────────────────────

class _ShowOnCardToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  const _ShowOnCardToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    // The whole row is tappable so the hit-target is never smaller than the
    // Switch needs. Constraining the Switch into a tiny SizedBox (the old
    // approach) clipped its tap region, which still registered in debug builds
    // but silently failed in release/profile builds on Android.
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            const Text('Show on card',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 13)),
            const SizedBox(width: 8),
            Switch(
              value: value,
              onChanged: onChanged,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ],
        ),
      ),
    );
  }
}

class _Dropdown extends StatelessWidget {
  final String label;
  final String? value;
  final List<String> items;
  final ValueChanged<String?> onChanged;

  const _Dropdown({
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: items
            .map((e) => DropdownMenuItem(value: e, child: Text(e)))
            .toList(),
        onChanged: onChanged,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: 4),
      child: Text(text, style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: AppColors.primary,
        letterSpacing: 0.5,
      )),
    );
  }
}

class _Field extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String? hint;
  final TextInputType keyboardType;
  final bool required;
  final String? Function(String?)? validator;

  const _Field(
    this.controller,
    this.label, {
    this.hint,
    this.keyboardType = TextInputType.text,
    this.required = false,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(labelText: label, hintText: hint),
        validator: validator ??
            (required
                ? (v) => (v == null || v.trim().isEmpty) ? '$label is required' : null
                : null),
      ),
    );
  }
}

/// A title + description row with a trailing switch, used for the
/// "Print … on invoices" options. Styled to match the bank/UPI settings.
class _InvoiceToggle extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _InvoiceToggle({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppColors.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

// ── Pinned TabBar delegate ────────────────────────────────────

class _TabBarDelegate extends SliverPersistentHeaderDelegate {
  final TabBar tabBar;
  const _TabBarDelegate(this.tabBar);

  @override
  double get minExtent => tabBar.preferredSize.height;
  @override
  double get maxExtent => tabBar.preferredSize.height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: tabBar,
    );
  }

  @override
  bool shouldRebuild(_TabBarDelegate oldDelegate) => tabBar != oldDelegate.tabBar;
}

// ── Reference data ────────────────────────────────────────────

/// Basic UPI VPA (Virtual Payment Address) shape: handle@provider.
/// e.g. business@okhdfc, 9876543210@paytm, name.surname@oksbi.
final _upiRegex = RegExp(r'^[a-zA-Z0-9._-]{2,256}@[a-zA-Z]{2,64}$');

const _indianStates = [
  'Andhra Pradesh', 'Arunachal Pradesh', 'Assam', 'Bihar', 'Chhattisgarh', 'Goa',
  'Gujarat', 'Haryana', 'Himachal Pradesh', 'Jharkhand', 'Karnataka', 'Kerala',
  'Madhya Pradesh', 'Maharashtra', 'Manipur', 'Meghalaya', 'Mizoram', 'Nagaland',
  'Odisha', 'Punjab', 'Rajasthan', 'Sikkim', 'Tamil Nadu', 'Telangana', 'Tripura',
  'Uttar Pradesh', 'Uttarakhand', 'West Bengal', 'Andaman and Nicobar Islands',
  'Chandigarh', 'Dadra and Nagar Haveli and Daman and Diu', 'Delhi', 'Jammu and Kashmir',
  'Ladakh', 'Lakshadweep', 'Puducherry',
];

const _businessTypes = [
  'Retailer', 'Wholesaler', 'Distributor', 'Manufacturer', 'Service Provider', 'Trader',
];

const _businessCategories = [
  'Agriculture', 'Automobile', 'Cleaning & Pest Control', 'Computer & Mobile',
  'Construction & Hardware', 'Education', 'Electronics & Electrical',
  'Fashion & Apparel', 'Food & Beverages', 'Footwear', 'Furniture',
  'Grocery & General Store', 'Health & Pharmacy', 'Home & Kitchen',
  'Hotel & Restaurant', 'Jewellery', 'Logistics & Transport', 'Other',
  'Real Estate', 'Salon & Beauty', 'Stationery & Books', 'Textiles',
];
