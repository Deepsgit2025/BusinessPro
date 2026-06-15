import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Reusable 4-digit PIN entry: four dots, a subtitle/error row, and a custom
/// numeric keypad. Shakes + clears on error, and gives light haptic feedback on
/// every key press.
///
/// All accent colours come from `Theme.of(context).colorScheme.primary` so the
/// widget tracks the app theme (and light/dark) automatically.
class PinInputWidget extends StatefulWidget {
  /// Called when the 4th digit is entered, with the full 4-char PIN.
  final ValueChanged<String> onComplete;

  /// When non-null: shown in red below the dots, triggers a shake, and clears
  /// the entered digits.
  final String? errorMessage;

  /// Called ~2s after an error is shown, so the parent can clear [errorMessage].
  final VoidCallback? onErrorShown;

  /// Shown below the dots when there is no error.
  final String? subtitle;

  const PinInputWidget({
    super.key,
    required this.onComplete,
    this.errorMessage,
    this.onErrorShown,
    this.subtitle,
  });

  @override
  State<PinInputWidget> createState() => _PinInputWidgetState();
}

class _PinInputWidgetState extends State<PinInputWidget>
    with SingleTickerProviderStateMixin {
  static const int _pinLength = 4;

  String _entered = '';

  late final AnimationController _shakeController;
  late final Animation<double> _shakeAnimation;
  Timer? _errorTimer;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -12), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -12, end: 12), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 12, end: -8), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8, end: 8), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8, end: 0), weight: 1),
    ]).animate(
      CurvedAnimation(parent: _shakeController, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(covariant PinInputWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.errorMessage != null &&
        widget.errorMessage != oldWidget.errorMessage) {
      _onError();
    }
  }

  void _onError() {
    setState(() => _entered = '');
    _shakeController.forward(from: 0);
    _errorTimer?.cancel();
    if (widget.onErrorShown != null) {
      _errorTimer = Timer(
        const Duration(seconds: 2),
        () => widget.onErrorShown?.call(),
      );
    }
  }

  void _onKeyTap(String digit) {
    HapticFeedback.lightImpact();
    if (_entered.length >= _pinLength) return;
    setState(() => _entered += digit);
    if (_entered.length == _pinLength) {
      final pin = _entered;
      // Defer so the final dot paints before the parent reacts.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onComplete(pin);
      });
    }
  }

  void _onBackspace() {
    HapticFeedback.lightImpact();
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  @override
  void dispose() {
    _errorTimer?.cancel();
    _shakeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final hasError = widget.errorMessage != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _shakeAnimation,
          builder: (context, child) => Transform.translate(
            offset: Offset(_shakeAnimation.value, 0),
            child: child,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(_pinLength, (i) {
              final filled = i < _entered.length;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                margin: const EdgeInsets.symmetric(horizontal: 12),
                width: 16,
                height: 16,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: filled ? primary : Colors.transparent,
                  border: Border.all(
                    color: filled
                        ? primary
                        : theme.colorScheme.onSurface.withValues(alpha: 0.35),
                    width: 1.6,
                  ),
                ),
              );
            }),
          ),
        ),
        const SizedBox(height: 20),
        SizedBox(
          height: 24,
          child: Text(
            hasError
                ? widget.errorMessage!
                : (widget.subtitle ?? ''),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: hasError
                  ? theme.colorScheme.error
                  : theme.colorScheme.onSurface.withValues(alpha: 0.65),
              fontWeight: hasError ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        const SizedBox(height: 28),
        _Keypad(onDigit: _onKeyTap, onBackspace: _onBackspace),
      ],
    );
  }
}

class _Keypad extends StatelessWidget {
  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;

  const _Keypad({required this.onDigit, required this.onBackspace});

  @override
  Widget build(BuildContext context) {
    Widget digit(String d) => _KeypadButton(
          onTap: () => onDigit(d),
          child: Text(
            d,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
          ),
        );

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [digit('1'), digit('2'), digit('3')],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [digit('4'), digit('5'), digit('6')],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [digit('7'), digit('8'), digit('9')],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const SizedBox(width: 80, height: 80),
              digit('0'),
              _KeypadButton(
                onTap: onBackspace,
                child: Icon(
                  Icons.backspace_outlined,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _KeypadButton extends StatelessWidget {
  final Widget child;
  final VoidCallback onTap;

  const _KeypadButton({required this.child, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 80,
            height: 80,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
