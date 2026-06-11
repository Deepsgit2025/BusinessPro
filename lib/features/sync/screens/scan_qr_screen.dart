import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/constants/app_colors.dart';
import '../../../core/constants/app_strings.dart';
import '../../../core/database/database_helper.dart';
import '../../../services/sync/qr_link_service.dart';
import '../../../services/sync/sync_models.dart';
import '../../../services/sync/sync_providers.dart';

/// Windows-side device linking. Scans the QR shown on Android (or accepts the
/// code typed manually), fetches the Drive token from Firebase, stores it, and
/// kicks off the first sync.
class ScanQrScreen extends ConsumerStatefulWidget {
  const ScanQrScreen({super.key});

  @override
  ConsumerState<ScanQrScreen> createState() => _ScanQrScreenState();
}

class _ScanQrScreenState extends ConsumerState<ScanQrScreen> {
  final _qr = QrLinkService();
  final _manualController = TextEditingController();
  final _scannerController = MobileScannerController();
  bool _processing = false;
  bool _handled = false; // guards against repeated scan callbacks

  @override
  void dispose() {
    _manualController.dispose();
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || _processing) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (raw == null) return;
    _handled = true;
    await _link(raw);
  }

  Future<void> _linkManual() async {
    final code = _manualController.text.trim();
    if (code.isEmpty) return;
    await _link(code);
  }

  Future<void> _link(String code) async {
    setState(() => _processing = true);
    try {
      final result = await _qr.fetchTokenFromCode(code);
      if (!mounted) return;

      if (!result.isSuccess) {
        _handled = false;
        setState(() => _processing = false);
        _toast(result.status == LinkStatus.expired
            ? 'That code has expired. Generate a new one on Android.'
            : 'Code not found. Check it and try again.');
        return;
      }

      // Persist the handed-off token (Windows auth uses the cached token). Give
      // it the same ~55-minute window Android assumes; the user re-links when
      // it lapses.
      await DatabaseHelper.setSetting(
          AppStrings.kDriveAccessToken, result.accessToken!);
      await DatabaseHelper.setSetting(
        AppStrings.kDriveTokenExpiry,
        DateTime.now().add(const Duration(minutes: 55)).toIso8601String(),
      );

      // Register the Android device locally so it appears in the device list.
      await ref.read(syncRepositoryProvider).upsertDevice(SyncDevice(
            deviceId: result.androidDeviceId!,
            deviceName: result.androidDeviceName ?? 'Android device',
            deviceType: 'android',
            linkedAt: DateTime.now(),
            lastSeen: DateTime.now(),
          ));
      refreshSyncStateW(ref);

      // First sync immediately (silent — errors won't surface here).
      final engine = ref.read(syncEngineProvider);
      if (engine != null) {
        await engine.sync();
        refreshSyncStateW(ref);
      }

      if (!mounted) return;
      _toast('Linked to Android device successfully.');
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      _handled = false;
      setState(() => _processing = false);
      _toast('Could not link. Check your connection and try again.');
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Link to Android Device')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'On your Android phone, open BusinessPro → Settings → Sync & '
              'Devices → Link New Windows Device. Point the camera at the QR '
              'code that appears.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 20),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 280,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      controller: _scannerController,
                      onDetect: _onDetect,
                      errorBuilder: (context, error, child) =>
                          _ScannerError(error: error),
                    ),
                    if (_processing)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: CircularProgressIndicator(color: Colors.white),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Row(
              children: [
                Expanded(child: Divider()),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: Text('or enter code manually',
                      style: TextStyle(color: AppColors.textSecondary)),
                ),
                Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _manualController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      hintText: 'e.g. A1B2C3D4',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    onSubmitted: (_) => _linkManual(),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  style:
                      FilledButton.styleFrom(backgroundColor: AppColors.primary),
                  onPressed: _processing ? null : _linkManual,
                  child: const Text('Link'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ScannerError extends StatelessWidget {
  final MobileScannerException error;
  const _ScannerError({required this.error});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.no_photography_outlined,
              color: Colors.white70, size: 40),
          const SizedBox(height: 12),
          const Text(
            'Camera unavailable.\nUse the manual code entry below.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70),
          ),
        ],
      ),
    );
  }
}
