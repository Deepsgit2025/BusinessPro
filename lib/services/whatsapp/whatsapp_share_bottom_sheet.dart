import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/constants/app_colors.dart';
import '../../features/parties/models/party.dart';
import '../../features/transactions/models/transaction.dart';
import '../../features/transactions/models/transaction_item.dart';
import 'whatsapp_invoice_service.dart';

/// Bottom sheet shown after a sale is saved (and from the manual menu) to send
/// the invoice image to the owner's and/or the customer's WhatsApp.
///
/// The invoice PNG is rendered in the background while a spinner shows; nothing
/// is stored — see [WhatsAppInvoiceService].
class WhatsAppShareBottomSheet extends StatefulWidget {
  final Transaction transaction;
  final List<TransactionItem> items;

  /// Business profile row (`DatabaseHelper.getBusiness()`), used for the owner's
  /// phone + name. May be null if the company profile has not been set up.
  final Map<String, dynamic>? business;

  /// Customer, used for the optional "Send to Customer" action.
  final Party? party;

  const WhatsAppShareBottomSheet({
    super.key,
    required this.transaction,
    required this.items,
    required this.business,
    required this.party,
  });

  static Future<void> show(
    BuildContext context, {
    required Transaction transaction,
    required List<TransactionItem> items,
    required Map<String, dynamic>? business,
    Party? party,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => WhatsAppShareBottomSheet(
        transaction: transaction,
        items: items,
        business: business,
        party: party,
      ),
    );
  }

  @override
  State<WhatsAppShareBottomSheet> createState() =>
      _WhatsAppShareBottomSheetState();
}

class _WhatsAppShareBottomSheetState extends State<WhatsAppShareBottomSheet> {
  static const _whatsappGreen = Color(0xFF25D366);
  static const _whatsappTeal = Color(0xFF128C7E);

  Uint8List? _pngBytes;
  bool _generating = true;
  bool _ownerSent = false;
  bool _busy = false;

  String get _invoiceNo => widget.transaction.transactionNumber;
  String? get _ownerPhone => (widget.business?['phone'] as String?)?.trim();
  String get _businessName =>
      (widget.business?['name'] as String?)?.trim().isNotEmpty == true
          ? (widget.business!['name'] as String).trim()
          : 'your business';

  @override
  void initState() {
    super.initState();
    _generate();
  }

  Future<void> _generate() async {
    final png = await WhatsAppInvoiceService.buildInvoicePng(
      transaction: widget.transaction,
      items: widget.items,
    );
    if (!mounted) return;
    setState(() {
      _pngBytes = png;
      _generating = false;
    });
  }

  /// The screen rect used to anchor the native Windows/iPad share flyout.
  /// Without this the Windows DataTransferManager flyout can open off-screen and
  /// lock the window.
  Rect? get _shareOrigin =>
      WhatsAppInvoiceService.originFromContext(context);

  Future<void> _sendToOwner() async {
    final png = _pngBytes;
    if (png == null || _busy) return;
    final phone = _ownerPhone;
    if (phone == null || phone.isEmpty) {
      _snack('Owner phone number not set in company profile');
      return;
    }
    setState(() => _busy = true);
    final result = await WhatsAppInvoiceService.shareInvoiceImage(
      pngBytes: png,
      baseName: _invoiceNo,
      phone: phone,
      message: '🧾 Sale Invoice $_invoiceNo\nPowered by BusinessPro',
      sharePositionOrigin: _shareOrigin,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result.success) _ownerSent = true;
    });
    if (result.error != null) {
      _snack(result.error!);
    } else if (result.success) {
      // Done — close the sheet so the user isn't left staring at a tick.
      Navigator.of(context).pop();
    }
  }

  Future<void> _sendToCustomer() async {
    final png = _pngBytes;
    final party = widget.party;
    if (png == null || party == null || _busy) return;
    setState(() => _busy = true);
    final result = await WhatsAppInvoiceService.shareInvoiceImage(
      pngBytes: png,
      baseName: _invoiceNo,
      phone: party.phone,
      message: 'Dear Customer,\nPlease find your invoice $_invoiceNo from '
          '$_businessName.\nThank you for your business! 🙏',
      sharePositionOrigin: _shareOrigin,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (result.error != null) {
      _snack(result.error!);
    } else if (result.success) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _shareAsPdf() async {
    if (_busy) return;
    final origin = _shareOrigin;
    setState(() => _busy = true);
    try {
      final pdf = await WhatsAppInvoiceService.buildInvoicePdf(
        transaction: widget.transaction,
        items: widget.items,
      );
      await WhatsAppInvoiceService.shareInvoicePdf(
        pdfBytes: pdf,
        baseName: _invoiceNo,
        sharePositionOrigin: origin,
      );
    } catch (e) {
      if (mounted) _snack('Could not share PDF: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final hasOwnerPhone = _ownerPhone != null && _ownerPhone!.isNotEmpty;
    final customerPhone = widget.party?.phone;
    final hasCustomerPhone = customerPhone != null && customerPhone.isNotEmpty;
    final imageReady = !_generating && _pngBytes != null;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[300],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Share Invoice',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            Text(_invoiceNo,
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 16),

            if (!hasOwnerPhone) _ownerPhoneBanner(),

            // Preview / loading.
            if (_generating)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Column(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 10),
                      Text('Preparing invoice image…'),
                    ],
                  ),
                ),
              )
            else if (_pngBytes != null)
              Center(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.memory(_pngBytes!,
                      height: 200, fit: BoxFit.contain),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'Could not render the invoice image. You can still share it '
                  'as a PDF below.',
                  style: TextStyle(color: Colors.grey[700], fontSize: 13),
                ),
              ),

            const SizedBox(height: 16),

            _ShareButton(
              icon: '📱',
              label: 'Send to My WhatsApp',
              subtitle: hasOwnerPhone
                  ? _ownerPhone!
                  : 'Set phone in company profile',
              color: _whatsappGreen,
              enabled: imageReady && hasOwnerPhone && !_busy,
              done: _ownerSent,
              onTap: _sendToOwner,
            ),

            if (hasCustomerPhone) ...[
              const SizedBox(height: 12),
              _ShareButton(
                icon: '👤',
                label: 'Send to Customer',
                subtitle: '${widget.party!.name} · $customerPhone',
                color: _whatsappTeal,
                enabled: imageReady && !_busy,
                onTap: _sendToCustomer,
              ),
            ],

            const SizedBox(height: 12),
            _ShareButton(
              icon: '📄',
              label: 'Share as PDF',
              subtitle: 'Email, Drive, Telegram…',
              color: Colors.grey[700]!,
              enabled: !_busy,
              onTap: _shareAsPdf,
            ),

            const SizedBox(height: 4),
            Center(
              child: TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: Text('Skip for now',
                    style: TextStyle(color: Colors.grey[600])),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _ownerPhoneBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: Colors.amber[100],
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber, color: Colors.amber[800], size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Add your phone number in company profile to send to your WhatsApp',
              style: TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushNamed(context, '/company-setup');
            },
            child: const Text('Set Now'),
          ),
        ],
      ),
    );
  }
}

class _ShareButton extends StatelessWidget {
  final String icon;
  final String label;
  final String subtitle;
  final Color color;
  final bool enabled;
  final bool done;
  final VoidCallback onTap;

  const _ShareButton({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.color,
    required this.enabled,
    required this.onTap,
    this.done = false,
  });

  @override
  Widget build(BuildContext context) {
    final active = enabled && !done;
    return Material(
      color: active ? color.withValues(alpha: 0.10) : Colors.grey[200],
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: active ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Text(icon, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: active ? color : Colors.grey,
                        )),
                    Text(subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12, color: AppColors.textSecondary)),
                  ],
                ),
              ),
              if (done)
                const Icon(Icons.check_circle, color: AppColors.primary)
              else
                Icon(Icons.arrow_forward_ios,
                    size: 14, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }
}
