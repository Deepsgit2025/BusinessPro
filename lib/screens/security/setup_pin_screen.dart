import 'package:flutter/material.dart';

import '../../widgets/security/pin_input_widget.dart';

/// Two-step PIN creation flow.
///
/// Step 1 collects a new PIN; step 2 confirms it. A mismatch returns the user
/// to step 1 with an explanatory error. On success it pops with the confirmed
/// PIN string — the caller is responsible for hashing + persisting it.
class SetupPinScreen extends StatefulWidget {
  const SetupPinScreen({super.key});

  @override
  State<SetupPinScreen> createState() => _SetupPinScreenState();
}

class _SetupPinScreenState extends State<SetupPinScreen> {
  int _step = 0; // 0 = create, 1 = confirm
  String? _firstPin;
  String? _errorMessage;

  void _onCreateComplete(String pin) {
    setState(() {
      _firstPin = pin;
      _step = 1;
      _errorMessage = null;
    });
  }

  void _onConfirmComplete(String pin) {
    if (pin == _firstPin) {
      Navigator.pop(context, pin);
    } else {
      setState(() {
        _step = 0;
        _firstPin = null;
        _errorMessage = 'PINs do not match. Try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isConfirm = _step == 1;

    return Scaffold(
      appBar: AppBar(
        title: Text(isConfirm ? 'Confirm PIN' : 'Create PIN'),
      ),
      body: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (child, animation) {
            final offset = Tween<Offset>(
              begin: const Offset(0.15, 0),
              end: Offset.zero,
            ).animate(animation);
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(position: offset, child: child),
            );
          },
          child: Center(
            key: ValueKey(_step),
            child: SingleChildScrollView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    isConfirm ? 'Confirm PIN' : 'Create PIN',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 40),
                  PinInputWidget(
                    // Distinct key so the field resets between steps.
                    key: ValueKey('pin_step_$_step'),
                    onComplete:
                        isConfirm ? _onConfirmComplete : _onCreateComplete,
                    errorMessage: _errorMessage,
                    onErrorShown: () {
                      if (mounted) setState(() => _errorMessage = null);
                    },
                    subtitle: isConfirm
                        ? 'Re-enter your PIN to confirm'
                        : 'Choose a 4-digit PIN',
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
