import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_colors.dart';
import '../../../services/sync/qr_link_service.dart';
import '../../../services/sync/sync_providers.dart';

/// Android-side device linking. Generates a short code, deposits the Drive token
/// under it in Firebase, and shows it as a QR (plus the plain code as a manual
/// fallback). The code expires after [QrLinkService.tokenTtlSeconds]; a countdown
/// runs and a fresh code is generated automatically on expiry.
class ShowQrScreen extends ConsumerStatefulWidget {
  const ShowQrScreen({super.key});

  @override
  ConsumerState<ShowQrScreen> createState() => _ShowQrScreenState();
}

class _ShowQrScreenState extends ConsumerState<ShowQrScreen> {
  final _qr = QrLinkService();
  String? _code;
  int _secondsLeft = QrLinkService.tokenTtlSeconds;
  Timer? _ticker;
  String? _error;
  bool _generating = false;

  @override
  void initState() {
    super.initState();
    _generate();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _error = null;
    });
    try {
      final auth = ref.read(authServiceProvider);
      final token = await auth.getAccessToken();
      if (token == null) {
        setState(() {
          _error = 'Not signed in. Go back and connect Google Drive first.';
          _generating = false;
        });
        return;
      }
      final deviceId = ref.read(deviceIdProvider);
      final code = await _qr.generateLinkCode(
        accessToken: token,
        deviceId: deviceId,
        deviceName: 'Android device',
      );
      if (!mounted) return;
      setState(() {
        _code = code;
        _secondsLeft = QrLinkService.tokenTtlSeconds;
        _generating = false;
      });
      _startTicker();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not create a link code. Check your connection.';
        _generating = false;
      });
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (_secondsLeft <= 1) {
        t.cancel();
        _generate(); // auto-regenerate on expiry
      } else {
        setState(() => _secondsLeft--);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Show Link Code')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'On your Windows PC, open BusinessPro → Settings → Sync & Devices '
              '→ Link to Android Device, then type the code below.',
              style: TextStyle(color: AppColors.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 28),
            if (_error != null)
              _ErrorBox(message: _error!, onRetry: _generate)
            else
              _CodeBlock(
                code: _code,
                generating: _generating,
                secondsLeft: _secondsLeft,
              ),
            const SizedBox(height: 28),
            OutlinedButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('Generate New Code'),
              onPressed: _generating ? null : _generate,
            ),
            const SizedBox(height: 16),
            const Text(
              'Keep this screen open until the Windows device confirms it is '
              'linked. The code is single-use and expires automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textHint, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  final String? code;
  final bool generating;
  final int secondsLeft;
  const _CodeBlock({
    required this.code,
    required this.generating,
    required this.secondsLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          child: (generating || code == null)
              ? const SizedBox(
                  height: 64, child: Center(child: CircularProgressIndicator()))
              : Column(
                  children: [
                    const Text('YOUR LINK CODE',
                        style: TextStyle(
                            fontSize: 12,
                            letterSpacing: 1.5,
                            color: AppColors.textSecondary,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 10),
                    SelectableText(
                      code!,
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 6,
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextButton.icon(
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy code'),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: code!));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Code copied')),
                        );
                      },
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        if (code != null) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.timer_outlined,
                  size: 16, color: AppColors.textSecondary),
              const SizedBox(width: 6),
              Text(
                'Expires in ${secondsLeft}s',
                style: const TextStyle(color: AppColors.textSecondary),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _ErrorBox extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBox({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.expense.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.expense.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          const Icon(Icons.error_outline, color: AppColors.expense, size: 36),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Try Again')),
        ],
      ),
    );
  }
}
