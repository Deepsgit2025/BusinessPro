import 'package:flutter/material.dart';

import '../../services/security/app_lock_service.dart';
import '../../widgets/security/pin_input_widget.dart';
import 'setup_pin_screen.dart';

/// Security settings: enable/disable the PIN lock and change the PIN.
///
/// All hash persistence is delegated to [onChanged] — this screen drives the
/// [AppLockService] but never touches the DB itself.
class SecuritySettingsScreen extends StatefulWidget {
  /// Called whenever the PIN is enabled, disabled or changed.
  /// [enabled] reflects the new state; [hash] is the hash to persist (null when
  /// disabling).
  final void Function(bool enabled, String? hash)? onChanged;

  const SecuritySettingsScreen({super.key, this.onChanged});

  @override
  State<SecuritySettingsScreen> createState() => _SecuritySettingsScreenState();
}

class _SecuritySettingsScreenState extends State<SecuritySettingsScreen> {
  AppLockService get _service => AppLockService.instance;

  Future<void> _onToggle(bool value) async {
    if (value) {
      await _enable();
    } else {
      await _disable();
    }
  }

  Future<void> _enable() async {
    final pin = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const SetupPinScreen()),
    );
    if (pin == null) return; // cancelled
    final hash = _service.enablePin(pin);
    widget.onChanged?.call(true, hash);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN lock enabled')),
      );
    }
  }

  Future<void> _disable() async {
    final current = await _verifyPin(title: 'Enter current PIN to turn off');
    if (current == null) return;
    try {
      _service.disablePin(current);
      widget.onChanged?.call(false, null);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN lock disabled')),
        );
      }
    } on WrongPinException {
      _showError('Wrong PIN. PIN lock unchanged.');
    }
  }

  Future<void> _changePin() async {
    final current = await _verifyPin(title: 'Enter current PIN');
    if (current == null) return;
    // Validate the current PIN up front so we don't push the setup flow for
    // nothing.
    if (!_service.verifyPin(current)) {
      _showError('Wrong PIN. PIN unchanged.');
      return;
    }
    if (!mounted) return;
    final newPin = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const SetupPinScreen()),
    );
    if (newPin == null) return;
    try {
      final hash = _service.changePin(currentPin: current, newPin: newPin);
      widget.onChanged?.call(true, hash);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PIN changed')),
        );
      }
    } on WrongPinException {
      _showError('Wrong PIN. PIN unchanged.');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Shows a modal bottom sheet asking for the current PIN. Returns the entered
  /// PIN string, or null if dismissed.
  Future<String?> _verifyPin({required String title}) {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _VerifyPinSheet(title: title),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: ListenableBuilder(
        listenable: _service,
        builder: (context, _) {
          final enabled = _service.pinEnabled;
          return ListView(
            children: [
              SwitchListTile(
                value: enabled,
                onChanged: _onToggle,
                secondary:
                    Icon(Icons.lock_outline, color: theme.colorScheme.primary),
                title: const Text('PIN Lock'),
                subtitle: Text(
                  enabled
                      ? 'App asks for a 4-digit PIN on open'
                      : 'Protect the app with a 4-digit PIN',
                ),
              ),
              if (enabled) ...[
                const Divider(height: 0),
                ListTile(
                  leading: Icon(Icons.pin_outlined,
                      color: theme.colorScheme.primary),
                  title: const Text('Change PIN'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _changePin,
                ),
              ],
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline,
                          size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'The PIN is stored only on this device and is never '
                          'sent anywhere. If you forget it, the only way to '
                          'regain access is to uninstall and reinstall the app '
                          '(which erases local data — restore from a backup '
                          'afterwards).',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

/// Bottom-sheet body that collects a PIN for verification and pops it back.
class _VerifyPinSheet extends StatefulWidget {
  final String title;
  const _VerifyPinSheet({required this.title});

  @override
  State<_VerifyPinSheet> createState() => _VerifyPinSheetState();
}

class _VerifyPinSheetState extends State<_VerifyPinSheet> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 20),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 28),
              PinInputWidget(
                onComplete: (pin) => Navigator.pop(context, pin),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
