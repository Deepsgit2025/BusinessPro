import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/security/app_lock_service.dart';
import '../../widgets/security/pin_input_widget.dart';

/// Full-screen lock overlay shown by [AppLockWrapper] when the app is locked.
///
/// Has no AppBar and no back affordance — it cannot be dismissed without the
/// correct PIN. While in a post-lockout cool-down it hides the keypad and shows
/// a live countdown instead.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key});

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _service = AppLockService.instance;

  String? _errorMessage;
  Timer? _lockoutTicker;
  int? _lockoutRemaining;

  @override
  void initState() {
    super.initState();
    if (_service.isInLockout) _startLockoutTicker();
  }

  void _startLockoutTicker() {
    _lockoutTicker?.cancel();
    _lockoutRemaining = _service.lockoutSecondsRemaining;
    _lockoutTicker = Timer.periodic(const Duration(seconds: 1), (timer) {
      final remaining = _service.lockoutSecondsRemaining;
      if (remaining == null) {
        timer.cancel();
        if (mounted) setState(() => _lockoutRemaining = null);
        return;
      }
      if (mounted) setState(() => _lockoutRemaining = remaining);
    });
  }

  void _onComplete(String pin) {
    try {
      _service.tryUnlock(pin);
      // Success: AppLockWrapper rebuilds and removes this screen.
    } on LockoutException catch (e) {
      setState(() {
        _errorMessage = _lockoutMessage(e.secondsRemaining);
      });
      _startLockoutTicker();
    } on WrongPinException {
      final left = AppLockService.instance.failedAttempts;
      final attemptsLeft = (5 - left).clamp(0, 5);
      setState(() {
        _errorMessage = 'Wrong PIN. $attemptsLeft attempts left.';
      });
    }
  }

  String _lockoutMessage(int seconds) {
    final m = seconds ~/ 60;
    final s = seconds % 60;
    final parts = <String>[];
    if (m > 0) parts.add('${m}m');
    parts.add('${s}s');
    return 'Too many attempts. Try again in ${parts.join(' ')}.';
  }

  @override
  void dispose() {
    _lockoutTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final inLockout = _lockoutRemaining != null;

    return PopScope(
      canPop: false,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: primary.withValues(alpha: 0.10),
                    ),
                    child: Icon(
                      inLockout ? Icons.timer_outlined : Icons.lock_outline,
                      size: 40,
                      color: primary,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'BusinessPro',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    inLockout
                        ? _lockoutMessage(_lockoutRemaining!)
                        : 'Enter your PIN to continue',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: inLockout
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 40),
                  if (inLockout)
                    _LockoutBox(remaining: _lockoutRemaining!)
                  else
                    PinInputWidget(
                      onComplete: _onComplete,
                      errorMessage: _errorMessage,
                      onErrorShown: () {
                        if (mounted) setState(() => _errorMessage = null);
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LockoutBox extends StatelessWidget {
  final int remaining;
  const _LockoutBox({required this.remaining});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = remaining ~/ 60;
    final s = remaining % 60;
    final text =
        m > 0 ? '${m}m ${s.toString().padLeft(2, '0')}s' : '${s}s';
    return Column(
      children: [
        Icon(Icons.lock_clock_outlined,
            size: 48, color: theme.colorScheme.error),
        const SizedBox(height: 16),
        Text(
          text,
          style: theme.textTheme.headlineMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.error,
          ),
        ),
      ],
    );
  }
}
